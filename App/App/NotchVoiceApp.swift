import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {

    /// TEMPORARY (Task 9 harness): the tap must be held strongly, otherwise it
    /// deinits immediately and tears its own event tap down.
    @MainActor private var debugTap: ModifierTap?

    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchVoice] launched")

        // TEMPORARY: manual verification harness for the modifier tap (Task 9).
        // Replaces the Task 8 paste harness. Revert once a human has confirmed
        // the checks below. Every step logs, because the failure mode that
        // matters (a silent no-op) looks exactly like a hang.
        Task { @MainActor in
            let binding = BindingStore.binding
            NSLog("[NotchVoice] binding: %@ (keycode %d)",
                  binding.displayName, Int(binding.rawValue))

            let tap = ModifierTap(binding: binding)
            tap.onKeyDown = { NSLog("[NotchVoice] DOWN") }
            tap.onKeyUp = { NSLog("[NotchVoice] UP") }
            tap.onOtherKey = { NSLog("[NotchVoice] OTHER") }
            tap.onEscape = { NSLog("[NotchVoice] ESC") }

            let started = tap.start()
            NSLog("[NotchVoice] tap started: %@", started ? "yes" : "no")

            guard started else {
                // Not a crash and not a hang: tapCreate returns nil when Input
                // Monitoring is not granted, and that is the only way to find
                // out. Say so explicitly so the empty log is not read as one.
                NSLog("[NotchVoice] Input Monitoring is NOT granted — no events will arrive.")
                NSLog("[NotchVoice] Grant it in System Settings > Privacy & Security >")
                NSLog("[NotchVoice] Input Monitoring, then relaunch this binary.")
                return
            }
            self.debugTap = tap

            NSLog("[NotchVoice] tap is live. Expected log for each check:")
            NSLog("[NotchVoice]   tap %@            -> DOWN then UP", binding.displayName)
            NSLog("[NotchVoice]   tap the LEFT twin      -> nothing")
            NSLog("[NotchVoice]   hold %@ + press o -> DOWN then OTHER", binding.displayName)
            NSLog("[NotchVoice]   press Esc alone        -> ESC")
            NSLog("[NotchVoice]   type a normal sentence -> nothing")
            NSLog("[NotchVoice] NOW THE ONE THAT MATTERS — nothing may be swallowed.")
            NSLog("[NotchVoice] In TextEdit, with this running:")
            NSLog("[NotchVoice]   type a full sentence -> every character appears")
            NSLog("[NotchVoice]   press left-opt + o   -> types o-slash")
            NSLog("[NotchVoice]   press %@ + o    -> types o-slash (binding must still compose)",
                  binding.displayName)
            NSLog("[NotchVoice]   press opt + left arrow -> cursor jumps a whole word")
            NSLog("[NotchVoice] Any missing keystroke means the tap is not observe-only.")
        }
    }
}
