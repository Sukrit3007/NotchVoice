import AppKit
import Sparkle

/// Checks for new versions and installs them.
///
/// The app is not notarized, so it cannot be updated through the App Store and
/// a user who had to click past Gatekeeper once should not have to do it again
/// every release. Sparkle verifies that an update is signed by the same
/// identity as the copy already running, which is a stronger check than
/// Gatekeeper performs on first launch.
@MainActor
final class UpdateController {

    /// Owns the updater. Sparkle stops checking the moment this is released,
    /// with nothing logged — the app would simply never see another version.
    private let controller: SPUStandardUpdaterController

    private let driverDelegate = GentleReminders()

    init() {
        // `startingUpdater: true` begins the scheduled check immediately.
        // Nothing here is user-facing until an update actually exists.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: driverDelegate)
    }

    /// The menu item. Always offers an answer, including "you're up to date".
    func checkForUpdates() {
        // Without this the update window opens behind whatever the user is
        // working in: an accessory app has no Dock icon and does not come
        // forward on its own, so the click would look like it did nothing.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}

/// Lets Sparkle handle a background-found update quietly.
///
/// Without this, a scheduled check that finds something throws a window in
/// front of whatever the user is doing — in an app whose whole point is not
/// interrupting you mid-sentence.
private final class GentleReminders: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
