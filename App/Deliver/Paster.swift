import AppKit
import ApplicationServices
import NotchVoiceCore

enum PasteOutcome {
    case pasted
    case copiedOnly
}

/// Delivers transcribed text into the app that had focus.
///
/// Uses a clipboard round-trip rather than an Accessibility text insertion:
/// `AXUIElementSetAttributeValue` fails or corrupts state in Electron apps,
/// terminals, and anything with a custom text engine, which is most of what
/// people dictate into. The clipboard plus a synthetic ⌘V works everywhere.
///
/// The original clipboard is snapshotted at full fidelity (every UTI on every
/// item, raw bytes) and put back afterwards — but only if nothing else wrote
/// in the meantime. See `ClipboardGuard`.
enum Paster {

    /// How long the staged text stays on the clipboard before restore. Too
    /// short and slow apps have not consumed the paste yet; too long and the
    /// user notices their clipboard is briefly wrong.
    private static let pasteConsumeDelay = Duration.milliseconds(150)
    /// Time for the reactivated app to actually become frontmost.
    private static let activateSettleDelay = Duration.milliseconds(80)

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
        // Pasting into ourselves would double-insert or miss the real target.
        let targetIsSelf = focus?.bundleID == NotchVoice.bundleID

        guard isAccessibilityTrusted(), let focus, !targetIsSelf else {
            copyOnly(text)
            return .copiedOnly
        }

        focus.activate()
        try? await Task.sleep(for: activateSettleDelay)

        let snapshot = ClipboardSnapshot.capture()
        let changeCountAfterWrite = writeText(text)

        // Optimistic: this reports that ⌘V was posted, not that the target
        // acted on it. Nothing in the API surface can confirm the latter.
        let pasted = sendCommandV()
        try? await Task.sleep(for: pasteConsumeDelay)

        // Restore ONLY when ⌘V actually went out. If posting failed we return
        // .copiedOnly, and that return value promises the caller the transcript
        // is sitting on the clipboard for the user to paste by hand — restoring
        // here would quietly wipe the dictation and report success at the same
        // time, which is the worst of both.
        if pasted, ClipboardGuard.shouldRestore(
            changeCountAfterWrite: changeCountAfterWrite,
            currentChangeCount: NSPasteboard.general.changeCount
        ) {
            snapshot.restore()
        }

        return pasted ? .pasted : .copiedOnly
    }

    private static func copyOnly(_ text: String) {
        _ = writeText(text)
    }

    @discardableResult
    private static func writeText(_ text: String) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Posts ⌘V into the session event stream.
    ///
    /// Returns whether the events were *created and posted* — NOT whether the
    /// target consumed them. There is no such acknowledgement to read. In
    /// particular, `CGEvent.post` silently no-ops when Accessibility is not
    /// granted (verified: with `AXIsProcessTrusted() == false`, the source and
    /// both events still construct fine and this returns true). That is why the
    /// `isAccessibilityTrusted()` check in `deliver` is load-bearing rather than
    /// advisory — it is the only place the ungranted case can be caught.
    ///
    /// `flags` is assigned outright rather than OR-ed into what the source
    /// seeded, so a modifier the user happens to be holding cannot turn the
    /// synthetic ⌘V into ⌥⌘V.
    private static func sendCommandV() -> Bool {
        let vKeyCode: CGKeyCode = 9  // kVK_ANSI_V
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

/// Full-fidelity snapshot of the general pasteboard.
///
/// Stores every `(UTI, raw bytes)` pair on every item, so restoring rebuilds
/// the complete multi-type payload — images, styled text, and file references
/// all survive the round-trip, not just the plain-text fallback.
struct ClipboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    static func capture() -> ClipboardSnapshot {
        let captured = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        return ClipboardSnapshot(items: captured)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let rebuilt = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        // The clipboard has already been cleared at this point, so a failed
        // write leaves the user with an empty clipboard — the exact outcome
        // this type exists to prevent. Nothing can be done to recover it, but
        // it must not pass silently.
        if !pasteboard.writeObjects(rebuilt) {
            NSLog("[NotchVoice] clipboard restore FAILED — %d item(s) lost",
                  rebuilt.count)
        }
    }
}
