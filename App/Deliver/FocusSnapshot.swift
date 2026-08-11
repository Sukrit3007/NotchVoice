import AppKit

/// Which app owned the keyboard when the dictation chord fired.
///
/// Captured *before* the island window is shown. Showing a window first risks
/// AppKit reshuffling key focus, and then we would paste into the wrong place.
struct FocusSnapshot: Sendable {
    let pid: pid_t
    let bundleID: String?

    static func capture() -> FocusSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FocusSnapshot(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier
        )
    }

    /// Brings the captured app back to the front so the synthetic ⌘V lands
    /// in it rather than wherever focus drifted to.
    func activate() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }
}
