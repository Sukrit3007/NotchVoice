import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {

    /// The coordinator owns the event tap, the recorder and the model. An
    /// unretained one deinits immediately and silently stops delivering events.
    @MainActor private var coordinator: DictationCoordinator?

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
            coordinator.onPhaseChange = { phase in
                NSLog("[NotchVoice] phase: %@", String(describing: phase))
            }
            coordinator.start()
            self.coordinator = coordinator
        }
    }
}
