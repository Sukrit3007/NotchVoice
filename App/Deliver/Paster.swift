import AppKit
import ApplicationServices
import NotchVoiceCore

enum PasteOutcome {
    case pasted
    case copiedOnly
}

/// Delivers transcribed text into the app that had focus.
///
/// A clipboard round-trip rather than an Accessibility text insertion:
/// `AXUIElementSetAttributeValue` fails or corrupts state in Electron apps,
/// terminals, and anything with a custom text engine — most of what people
/// dictate into. Clipboard plus a synthetic ⌘V works everywhere.
///
/// **The paste is proved, not assumed** — the text is staged as a `PastePromise`
/// whose data-provider callback is evidence the target actually read it, and
/// where the target field exposes its length and selection, they are watched
/// until the paste shows up there. See `PasteLanding`.
///
/// The original clipboard is snapshotted at full fidelity and put back
/// afterwards — but only when the paste was consumed *and* nothing else wrote in
/// the meantime. See `ClipboardGuard`.
enum Paster {

    private static let deliveryGate = DeliveryGate()

    /// Stamped on every keystroke this app posts, in `eventSourceUserData`, so
    /// the app's own event tap can tell them from the user's and leave them
    /// alone. Any constant works; this one spells "NVPS".
    static let syntheticEventMarker: Int64 = 0x4E56_5053

    /// How long to wait for the target to ask for the promised data.
    ///
    /// Generous relative to the old blind 150ms wait, because this one is doing
    /// real work: a slow app under load can take a moment to service the paste,
    /// and concluding "not pasted" early means telling the user to press ⌘V
    /// themselves when it was already on its way.
    private static let consumeTimeout = Duration.milliseconds(250)
    /// Time for the reactivated app to actually become frontmost.
    private static let activateSettleDelay = Duration.milliseconds(80)
    /// Bounds every Accessibility call made to refocus the dictated field. The
    /// app is frontmost and should answer at once; one that does not gets the
    /// paste wherever its focus already is.
    private static let refocusBudget: TimeInterval = 0.2
    private static let refocusCallCap: TimeInterval = 0.1
    /// Time for a refocused field to become first responder before ⌘V lands.
    /// Only paid when focus actually had to be moved.
    private static let refocusSettleDelay = Duration.milliseconds(50)
    /// How long to watch the field for the paste to show up after the target
    /// read it. Web views and Electron apps apply a paste a beat after reading
    /// the clipboard, and calling a paste that did land "copied only" invites
    /// the user to paste it twice. Polling returns as soon as it shows, so the
    /// full wait is only paid when it never does.
    private static let landingTimeout = Duration.milliseconds(500)
    private static let landingPollInterval = Duration.milliseconds(50)
    /// Bounds each read of the field's length and selection.
    private static let fieldReadBudget: TimeInterval = 0.1
    private static let fieldReadCallCap: TimeInterval = 0.05

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links into Settings. Only call this
    /// from an explicit user action — it is noisy.
    static func promptForAccessibility() {
        // The key is spelled out rather than read from
        // `kAXTrustedCheckOptionPrompt`: that symbol imports as a global `var`,
        // which Swift 6 rejects as non-concurrency-safe shared mutable state.
        // The literal is the value that global holds — verified by printing the
        // constant from a scratch binary, not assumed.
        _ = AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    @MainActor
    static func deliver(_ text: String, to focus: FocusSnapshot?) async -> PasteOutcome {
        await deliveryGate.acquire()
        defer { Task { await deliveryGate.release() } }

        // Pasting into ourselves would double-insert or miss the real target.
        let targetIsSelf = focus?.bundleID == NotchVoice.bundleID

        guard isAccessibilityTrusted(), let focus, !targetIsSelf else {
            writePlainText(text)
            return .copiedOnly
        }

        focus.activate()
        try? await Task.sleep(for: activateSettleDelay)

        // Reactivation is a request, not proof. If the user has moved to a
        // different app while transcription ran, keep the text on the
        // clipboard instead of surprising that new app with an insertion.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid else {
            writePlainText(text)
            Log.deliver.notice("Original target is no longer frontmost — copied only")
            return .copiedOnly
        }

        if let element = focus.element,
           await !refocus(element.raw, selection: focus.selection, in: focus.pid) {
            writePlainText(text)
            Log.deliver.notice("Could not refocus the dictated field safely — copied only")
            return .copiedOnly
        }

        // The field the paste is aimed at: the one the dictation started in,
        // or — with no such field, as for Paste Last Transcript — whatever the
        // app has focused now. Measured itself, never "whatever has focus
        // later", and only while it holds the app's focus. Nil `before` means
        // no check: the promise alone decides, as it did before this existed.
        let aimedAt = focus.element?.raw ?? focusedElement(in: focus.pid)
        let before = aimedAt.flatMap { checkableState(of: $0, in: focus.pid) }

        let snapshot = ClipboardSnapshot.capture()

        let promise = PastePromise(text: text)
        let changeCountAfterWrite = promise.write()

        guard sendCommandV() else {
            // Posting failed outright. Leave the transcript on the clipboard as
            // real text rather than an unresolved promise the user's next ⌘V
            // might not be able to read.
            writePlainText(text)
            return .copiedOnly
        }

        let consumed = await promise.waitForConsumption(within: consumeTimeout)

        guard consumed else {
            Log.deliver.notice("No app requested the pasted data — leaving it on the clipboard")
            // Deliberately NOT restored. The `.copiedOnly` return promises the
            // caller that the transcript is sitting on the clipboard for the
            // user to paste by hand; restoring here would wipe the dictation and
            // report it as merely-copied at the same time, which is the worst of
            // both. Re-written as plain text so it survives the promise going
            // out of scope.
            writePlainText(text)
            return .copiedOnly
        }

        // Read is not the same as landed: a field that cannot take text, or a
        // clipboard manager answering in the target's place, both satisfy the
        // promise. Same handling as an unread paste, and for the same reason.
        if let aimedAt, let before, await !landed(in: aimedAt, pid: focus.pid, before: before) {
            Log.deliver.notice("Paste was read but the field did not change — copied only")
            writePlainText(text)
            return .copiedOnly
        }

        if ClipboardGuard.shouldRestore(
            changeCountAfterWrite: changeCountAfterWrite,
            currentChangeCount: NSPasteboard.general.changeCount
        ) {
            snapshot.restore()
        }

        return .pasted
    }

    /// Puts keyboard focus back on the field the dictation started in, with
    /// the caret where it was. Returns false only when pasting now would be
    /// unsafe.
    ///
    /// Re-activating the app restores its key window, not the field: a click
    /// into another field or tab of the same app while transcription ran would
    /// otherwise take the paste. When the app's focus cannot be read, or the
    /// caret was never captured, focus is left alone and the paste goes where
    /// it is now, as it did before this existed.
    ///
    /// **Focus is moved only when the caret can be put back.** AppKit selects
    /// a single-line field's whole contents as it takes focus — verified: an
    /// `NSTextField` with its caret at the end reads `{0, 26}` of 26 after an
    /// Accessibility focus — so ⌘V would replace what was there. The caret
    /// captured at key-down is written back straight after; if the focus or
    /// the caret write fails, the caller falls back to Copy-only Delivery
    /// rather than risk pasting over a selection.
    @MainActor
    private static func refocus(
        _ element: AXUIElement, selection: CFRange?, in pid: pid_t
    ) async -> Bool {
        let budget = AX.budget(total: refocusBudget, perCallCap: refocusCallCap)
        let app = AXUIElementCreateApplication(pid)

        // Unknown is not "moved". Focusing a field that already has focus
        // selects all of it too, and a set that times out on our side still
        // runs in the app later — possibly after the ⌘V.
        guard let current = AX.element(kAXFocusedUIElementAttribute, of: app, within: budget)
        else {
            Log.deliver.notice("Could not read the app's focus — leaving it alone")
            return true
        }
        if CFEqual(current, element) { return true }

        guard let selection else {
            Log.deliver.notice("Focus moved within the app, but the caret is unknown — leaving it alone")
            return true
        }

        if let window = AX.element(kAXWindowAttribute, of: element, within: budget) {
            AX.perform(kAXRaiseAction, on: window, within: budget)
        }
        // A failed set is not proof nothing happened: one that timed out can
        // still land, select-all included, after the ⌘V has gone in. Same
        // fallback as a caret that will not go back.
        guard AX.set(kAXFocusedAttribute, to: true, of: element, within: budget) else {
            Log.deliver.notice("Focus moved within the app, and the field would not take it back")
            return false
        }
        let restored = AX.set(kAXSelectedTextRangeAttribute, to: selection, of: element, within: budget)
        Log.deliver.info("Refocused the dictated field — caret restored: \(restored, privacy: .public)")
        try? await Task.sleep(for: refocusSettleDelay)
        return restored
    }

    @MainActor
    private static func focusedElement(in pid: pid_t) -> AXUIElement? {
        let budget = AX.budget(total: fieldReadBudget, perCallCap: fieldReadCallCap)
        return AX.element(
            kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(pid), within: budget)
    }

    /// Whether `element` is the app's focused element right now.
    ///
    /// Chromium and Electron apply a refocus a beat late, and until they do the
    /// paste is not going into the field being measured. Unreadable counts as
    /// no.
    @MainActor
    private static func hasFocus(_ element: AXUIElement, in pid: pid_t) -> Bool {
        guard let current = focusedElement(in: pid) else { return false }
        return CFEqual(current, element)
    }

    /// The aimed-at field's state before the paste, when the check afterwards
    /// can be trusted: the field has the app's focus, its role is readable, and
    /// it is not a password field — even a password's length is not this
    /// app's business.
    @MainActor
    private static func checkableState(
        of element: AXUIElement, in pid: pid_t
    ) -> PasteLanding.FieldState? {
        guard hasFocus(element, in: pid) else { return nil }
        let budget = AX.budget(total: fieldReadBudget, perCallCap: fieldReadCallCap)
        guard let role = AX.string(kAXRoleAttribute, of: element, within: budget),
              role != "AXSecureTextField"
        else { return nil }
        return fieldState(of: element)
    }

    /// The field's length and selection — two numbers, never its text.
    @MainActor
    private static func fieldState(of element: AXUIElement) -> PasteLanding.FieldState? {
        let budget = AX.budget(total: fieldReadBudget, perCallCap: fieldReadCallCap)
        guard let count = AX.int(kAXNumberOfCharactersAttribute, of: element, within: budget),
              let selection = AX.range(kAXSelectedTextRangeAttribute, of: element, within: budget)
        else { return nil }
        return PasteLanding.FieldState(
            characterCount: count,
            selectionLocation: selection.location,
            selectionLength: selection.length)
    }

    /// Watches the aimed-at field until the paste shows up, or the timeout
    /// passes.
    ///
    /// Anything uncertain counts as landed — the field stops being readable,
    /// or stops holding the app's focus — because a false "copied" invites the
    /// user to paste a second time, and the promise already said the target
    /// read it.
    @MainActor
    private static func landed(
        in field: AXUIElement, pid: pid_t, before: PasteLanding.FieldState
    ) async -> Bool {
        var waited = Duration.zero
        while true {
            guard hasFocus(field, in: pid) else { return true }
            let verdict = PasteLanding.verdict(before: before, after: fieldState(of: field))
            if verdict != .notLanded { return true }
            guard waited < landingTimeout else { return false }
            try? await Task.sleep(for: landingPollInterval)
            waited += landingPollInterval
        }
    }

    @discardableResult
    private static func writePlainText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Posts ⌘V into the session event stream.
    ///
    /// Returns whether the events were created and posted — which is *not* the
    /// same as delivered. `CGEvent.post` silently no-ops without Accessibility,
    /// and both events still construct fine, so this returns true either way.
    /// That is why the `isAccessibilityTrusted()` check in `deliver` is
    /// load-bearing rather than advisory.
    ///
    /// `flags` is assigned outright rather than OR-ed into what the source
    /// seeded, so a modifier the user happens to be holding cannot turn the
    /// synthetic ⌘V into ⌥⌘V.
    ///
    /// The key is whichever one types "v" on the current layout — see
    /// `PasteKey`.
    @MainActor
    private static func sendCommandV() -> Bool {
        let vKeyCode = PasteKey.current()
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: vKeyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: vKeyCode, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}

/// Serializes clipboard and synthetic-keyboard delivery. Actors are reentrant,
/// so a boolean plus continuations is used instead of assuming actor isolation
/// alone will keep two `deliver` calls apart while one is awaiting AppKit.
private actor DeliveryGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard occupied else {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
