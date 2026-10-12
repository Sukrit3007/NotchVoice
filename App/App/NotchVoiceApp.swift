import AppKit

@main
final class NotchVoiceApp: NSObject, NSApplicationDelegate {

    /// The coordinator owns the event tap, the recorder and the model. An
    /// unretained one deinits immediately and silently stops delivering events.
    @MainActor private var coordinator: DictationCoordinator?
    @MainActor private var island: IslandWindowController?
    @MainActor private var menuBar: MenuBarController?
    @MainActor private var library: LibraryWindowController?
    @MainActor private var onboarding: OnboardingWindowController?
    /// Held for the process. Releasing it stops Sparkle checking, silently.
    @MainActor private var updates: UpdateController?
    /// Held for the process too. Ending it hands the app back to App Nap.
    @MainActor private var activity: (any NSObjectProtocol)?

    /// Starts the pipeline and surfaces anything still missing.
    ///
    /// Split out because it runs from two places: straight away on a normal
    /// launch, and after the first-run flow closes on the first one.
    @MainActor
    private func beginDictating(
        coordinator: DictationCoordinator,
        library: LibraryWindowController
    ) {
        Task {
            // Prompts on first launch; a no-op once answered. Held ahead of
            // start() so the very first hold-to-talk is not the thing that
            // raises the microphone dialog, mid-sentence.
            let granted = await PermissionChecker.requestMicrophone()
            if !granted {
                Log.audio.error("Microphone DENIED — capture will fail")
            }
            coordinator.start()

            // After start(), so the tap has been attempted: attempting one is
            // what gets this app listed under Input Monitoring, and a window
            // that sends the user to an empty list is worse than none.
            if library.showIfNeeded() {
                Log.settings.notice("Settings opened — a required permission is missing")
            }
        }
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = NotchVoiceApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// True when this process was launched only to host a test bundle.
    ///
    /// Load-bearing. Unit tests are injected into the running app rather than
    /// run standalone, so without this every `xcodebuild test` would arm a
    /// **consuming** event tap — swallowing fn across the whole machine for the
    /// duration — and kick off a 632MB model download.
    private static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Opens the window and starts nothing else — `--window-only`.
    ///
    /// For working on the window itself. Launching normally arms a consuming tap
    /// that swallows fn across the whole machine and spends twelve seconds
    /// loading a model, neither of which a design pass needs. Also how the
    /// screenshots get taken.
    private static var isWindowOnly: Bool {
        CommandLine.arguments.contains("--window-only")
    }

    /// Replays the first-run flow — `--onboarding`.
    ///
    /// Without it the only way to see this screen is to clear the preference on
    /// a real install, which means every look at it costs a round trip through
    /// System Settings. Does not mark onboarding complete.
    private static var replaysOnboarding: Bool {
        CommandLine.arguments.contains("--onboarding")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else {
            Log.dictation.info("Hosting tests — pipeline not started")
            return
        }

        if Self.isWindowOnly {
            Log.dictation.info("Window only — pipeline not started")
            MainActor.assumeIsolated {
                let coordinator = DictationCoordinator()
                let library = LibraryWindowController(coordinator: coordinator)
                library.show(pane: .history)
                self.coordinator = coordinator
                self.library = library
            }
            return
        }

        Log.dictation.info("Launched")

        // Synchronous, not `Task { @MainActor in … }`: this method already runs
        // on the main thread, and hopping would leave a window in which the app
        // is up with no tap armed.
        MainActor.assumeIsolated {
            // An accessory app with no visible window is exactly what App Nap
            // throttles — timers coalesced, priority lowered — and this one has
            // to answer a key press at any moment, with the tap watchdog and
            // the island's timers running on time. Idle *system* sleep stays
            // allowed: this keeps the app responsive, not the Mac awake.
            self.activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Waiting for the dictation key")

            let coordinator = DictationCoordinator()
            let island = IslandWindowController(coordinator: coordinator)

            // `weak island` breaks a cycle that would otherwise be
            // coordinator -> closure -> island -> coordinator. Both objects
            // live for the whole process here, so it would never be observed,
            // which is exactly why it would survive into a version where it is.
            coordinator.onPhaseChange = { [weak island] phase in
                Log.island.debug("Phase: \(String(describing: phase), privacy: .public)")
                island?.setVisible(for: phase)
                if phase == .recording {
                    island?.moveToActiveScreen()
                }
            }

            let library = LibraryWindowController(coordinator: coordinator)
            let updates = UpdateController()
            let menuBar = MenuBarController(
                coordinator: coordinator, library: library, updates: updates)
            menuBar.install()
            island.show()
            self.updates = updates

            // First run gets the guided flow instead of a permission dialog
            // arriving out of nowhere. It owns the prompts, so `start()` waits
            // until it is done — arming a tap behind it would put the app in
            // the Input Monitoring list before the screen explaining why.
            guard OnboardingPreference.isComplete, !Self.replaysOnboarding else {
                let onboarding = OnboardingWindowController(coordinator: coordinator)
                self.onboarding = onboarding
                Log.settings.notice("First run — showing onboarding")
                onboarding.show { [weak self] in
                    MainActor.assumeIsolated {
                        self?.beginDictating(coordinator: coordinator, library: library)
                    }
                }
                self.coordinator = coordinator
                self.island = island
                self.menuBar = menuBar
                self.library = library
                return
            }

            beginDictating(coordinator: coordinator, library: library)

            self.coordinator = coordinator
            self.island = island
            self.menuBar = menuBar
            self.library = library
        }
    }

}
