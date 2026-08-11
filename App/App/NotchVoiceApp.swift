import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchVoice] launched")

        // TEMPORARY: manual verification harness for paste delivery (Task 8).
        // Revert this block after a human confirms pasting into real apps.
        Task { @MainActor in
            // Nothing on this path throws — Paster.deliver swallows its own
            // failures and reports them through PasteOutcome — so there is no
            // do/catch here. Every step still logs, because the failure mode
            // that matters (a silent no-op) looks exactly like a hang.
            NSLog("[NotchVoice] accessibility trusted: %@",
                  Paster.isAccessibilityTrusted() ? "YES" : "NO")
            NSLog("[NotchVoice] switch to your target app now (5s)…")
            try? await Task.sleep(for: .seconds(5))

            let clipboardBefore = NSPasteboard.general.string(forType: .string)
            let focus = FocusSnapshot.capture()
            NSLog("[NotchVoice] target: %@ (pid %d)",
                  focus?.bundleID ?? "none", focus?.pid ?? -1)
            NSLog("[NotchVoice] clipboard before: %@", clipboardBefore ?? "<empty>")

            let outcome = await Paster.deliver("hello from notchvoice", to: focus)
            NSLog("[NotchVoice] outcome: %@", String(describing: outcome))

            let clipboardAfter = NSPasteboard.general.string(forType: .string)
            NSLog("[NotchVoice] clipboard after: %@", clipboardAfter ?? "<empty>")

            // What counts as correct depends on the outcome, so spell it out
            // rather than printing a bare restored YES/NO that reads as a bug
            // on the copiedOnly path.
            switch outcome {
            case .pasted:
                NSLog("[NotchVoice] expected clipboard to be RESTORED — %@",
                      clipboardBefore == clipboardAfter ? "OK" : "WRONG, clipboard was eaten")
            case .copiedOnly:
                NSLog("[NotchVoice] expected clipboard to HOLD THE TRANSCRIPT — %@",
                      clipboardAfter == "hello from notchvoice" ? "OK" : "WRONG")
            }
        }
    }
}
