import AppKit
import SwiftUI

/// Owns the Settings window.
///
/// The app runs as `.accessory` — no Dock icon, no menu bar of its own — but an
/// accessory app can still show and focus a normal window. The activation
/// policy is deliberately *not* switched to `.regular` while this is open: that
/// would make a Dock icon appear and disappear around a permissions dialog,
/// which looks like a second app launching.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private static let defaultSize = NSSize(width: 620, height: 460)
    private static let minimumSize = NSSize(width: 560, height: 420)

    private var window: NSWindow?
    private let coordinator: DictationCoordinator
    private let model: SettingsModel

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
        self.model = SettingsModel(coordinator: coordinator)
        super.init()
    }

    /// Opens the window if anything required is missing.
    ///
    /// Called at launch. Returns whether it opened, so the caller can tell the
    /// difference between "shown the user their problem" and "nothing to do".
    ///
    /// Lands on Permissions rather than General: this path only runs when the
    /// app cannot dictate at all, and dropping the user on a pane about launch
    /// behaviour would make them hunt for the reason they were interrupted.
    @discardableResult
    func showIfNeeded() -> Bool {
        // Readiness is checked as well as the permission panes because the two
        // can disagree: `IOHIDCheckAccess` reporting granted does not mean the
        // tap armed for *this* copy of the binary. If the coordinator could not
        // arm one, the app is dead however green System Settings looks.
        let blocked = !PermissionChecker.status().canDictate
            || coordinator.readiness == .needsPermission
        guard blocked else { return false }
        show(pane: .permissions)
        return true
    }

    /// Opens the window, optionally jumping to a pane.
    ///
    /// With no pane it opens wherever it was left — General the first time.
    /// Forcing it back to General on every open would throw away the user's
    /// place for no reason; only a specific problem earns a jump.
    func show(pane: SettingsPane? = nil) {
        if let pane { model.pane = pane }

        if let window {
            model.startPolling()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            // `.resizable` is new: a sidebar plus a detail pane is a layout
            // with two competing widths, and pinning it means the sidebar's
            // ideal width has to be right for every pane at once.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Voice Settings"
        window.titlebarAppearsTransparent = true
        window.minSize = Self.minimumSize
        window.delegate = self
        // Otherwise closing the window deallocates it out from under us and
        // the next open crashes rather than reusing it.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: SettingsView(model: model, coordinator: coordinator)
        )
        window.center()

        self.window = window
        model.startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Polling a hidden window would keep waking the process every 700ms for
        // state nobody is looking at. This also clears `onBindingKeyDown`, so a
        // window closed mid-test cannot leave a callback wired to a dead view.
        model.stopPolling()
    }
}
