import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {

    /// The coordinator owns the event tap, the recorder and the model. An
    /// unretained one deinits immediately and silently stops delivering events.
    @MainActor private var coordinator: DictationCoordinator?
    @MainActor private var island: IslandWindowController?

    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[NotchVoice] launched")

        // Synchronous, not `Task { @MainActor in … }`: this method already runs
        // on the main thread, and hopping would leave a window in which the app
        // is up with no tap armed.
        MainActor.assumeIsolated {
            let coordinator = DictationCoordinator()
            let island = IslandWindowController(coordinator: coordinator)

            // `weak island` breaks a cycle that would otherwise be
            // coordinator -> closure -> island -> coordinator. Both objects
            // live for the whole process here, so it would never be observed,
            // which is exactly why it would survive into a version where it is.
            coordinator.onPhaseChange = { [weak island] phase in
                NSLog("[NotchVoice] phase: %@", String(describing: phase))
                if phase == .recording {
                    island?.moveToActiveScreen()
                }
            }

            coordinator.start()
            island.show()

            self.coordinator = coordinator
            self.island = island

            Self.printManualChecklist()
        }
    }

    /// TEMPORARY (Task 10 harness): replaces the Task 9 tap harness. There is
    /// no UI yet, so the phase log is the only way to see the loop run. Revert
    /// once a human has worked through the checks below.
    @MainActor
    private static func printManualChecklist() {
        let binding = BindingStore.binding.displayName
        NSLog("[NotchVoice] --- manual checks (wait for 'model ready' first) ---")
        NSLog("[NotchVoice] Click into TextEdit, then:")
        NSLog("[NotchVoice]  1. hold %@, say \"hello world\", release", binding)
        NSLog("[NotchVoice]     -> recording, transcribing, done; text appears")
        NSLog("[NotchVoice]  2. double-tap %@, talk, tap again", binding)
        NSLog("[NotchVoice]     -> locked, transcribing, done; text appears")
        NSLog("[NotchVoice]  3. tap %@ once, wait", binding)
        NSLog("[NotchVoice]     -> recording, dormant; nothing pasted")
        NSLog("[NotchVoice]  4. hold %@, press o, release", binding)
        NSLog("[NotchVoice]     -> recording, dormant; nothing pasted; o-slash typed")
        NSLog("[NotchVoice]  5. hold %@, say nothing, release quickly", binding)
        NSLog("[NotchVoice]     -> tooShort, dormant")
        NSLog("[NotchVoice]  6. hold %@, say nothing, release after ~2s", binding)
        NSLog("[NotchVoice]     -> error(Nothing heard); a bare \".\" must NOT be pasted")
        NSLog("[NotchVoice]  7. hold %@, talk, press Esc", binding)
        NSLog("[NotchVoice]     -> dormant; nothing pasted")
        NSLog("[NotchVoice]  8. echo SENTINEL | pbcopy, dictate, then pbpaste")
        NSLog("[NotchVoice]     -> still prints SENTINEL")
        NSLog("[NotchVoice] --- end checks ---")
    }
}
