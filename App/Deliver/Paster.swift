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
/// whose data-provider callback is evidence the target actually read it.
///
/// The original clipboard is snapshotted at full fidelity and put back
/// afterwards — but only when the paste was consumed *and* nothing else wrote in
/// the meantime. See `ClipboardGuard`.
enum Paster {

    private static let deliveryGate = DeliveryGate()

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

        if let element = focus.element {
            await refocus(element.raw, in: focus.pid)
        }

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

        if ClipboardGuard.shouldRestore(
            changeCountAfterWrite: changeCountAfterWrite,
            currentChangeCount: NSPasteboard.general.changeCount
        ) {
            snapshot.restore()
        }

        return .pasted
    }

    /// Puts keyboard focus back on the field the dictation started in.
    ///
    /// Re-activating the app restores its key window, not the field: a click
    /// into another field or tab of the same app while transcription ran would
    /// otherwise take the paste. Best effort — a field that is gone or will not
    /// take focus leaves the paste going wherever focus is now, as it did
    /// before this existed.
    @MainActor
    private static func refocus(_ element: AXUIElement, in pid: pid_t) async {
        let budget = AX.budget(total: refocusBudget, perCallCap: refocusCallCap)
        let app = AXUIElementCreateApplication(pid)

        if let current = AX.element(kAXFocusedUIElementAttribute, of: app, within: budget),
           CFEqual(current, element) {
            return
        }

        if let window = AX.element(kAXWindowAttribute, of: element, within: budget) {
            AX.perform(kAXRaiseAction, on: window, within: budget)
        }
        let refocused = AX.set(kAXFocusedAttribute, to: true, of: element, within: budget)
        Log.deliver.info("Focus had moved within the app — refocused: \(refocused, privacy: .public)")
        if refocused {
            try? await Task.sleep(for: refocusSettleDelay)
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
