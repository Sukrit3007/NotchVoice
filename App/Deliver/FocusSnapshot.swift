import AppKit

/// Which app owned the keyboard when the dictation chord fired.
///
/// Captured *before* the island window is shown. Showing a window first risks
/// AppKit reshuffling key focus, and then we would paste into the wrong place.
struct FocusSnapshot: Sendable {
    let pid: pid_t
    let bundleID: String?

    /// Taken here rather than resolved from the bundle ID later, so history can
    /// still say "Slack" after Slack has been uninstalled.
    let appName: String?

    /// The focused field inside that app, so delivery can put focus back on it.
    ///
    /// Filled in a moment after capture, by the Accessibility read that runs
    /// off the main thread — finding it is IPC into the app, and the app is
    /// not allowed to delay the key-down. Nil when that read has not finished
    /// or the app exposes no focused element.
    var element: AXElement?

    static func capture() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusSnapshot(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName
        )
    }

    /// Brings the captured app back to the front so the synthetic ⌘V lands
    /// in it rather than wherever focus drifted to.
    func activate() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}
