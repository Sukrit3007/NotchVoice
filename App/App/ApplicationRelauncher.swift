import AppKit

/// Quits and reopens the app.
///
/// Only reached when Settings' live hotkey test has actually failed — the app
/// tries to re-arm the tap first and finds out whether a restart is genuinely
/// needed, rather than asserting it. See `DictationCoordinator.armTap()`.
///
/// `createsNewApplicationInstance` is what makes this work: without it the
/// workspace sees a running instance with this bundle identifier and simply
/// activates the copy that is about to terminate.
@MainActor
enum ApplicationRelauncher {
    static func restart() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let appURL = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            Log.settings.error("Cannot locate own bundle — not restarting")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                Log.settings.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        NSApplication.shared.terminate(nil)
    }
}
