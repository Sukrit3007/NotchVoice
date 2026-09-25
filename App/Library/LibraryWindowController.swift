import AppKit
import SwiftUI

/// Owns the app's window.
///
/// The app runs as `.accessory` — no Dock icon, no menu bar of its own — but an
/// accessory app can still show and focus a normal window. The activation policy
/// is deliberately *not* switched to `.regular` while this is open: that would
/// make a Dock icon appear and disappear around a permissions dialog, which
/// looks like a second app launching.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {

    /// Wider than a settings window because this one holds lists. Tall enough
    /// that a day of history is visible without scrolling.
    private static let defaultSize = NSSize(width: 860, height: 580)
    private static let minimumSize = NSSize(width: 680, height: 440)

    private var window: NSWindow?
    private let coordinator: DictationCoordinator
    private let model: SettingsModel
    private let stack: DataStack

    init(coordinator: DictationCoordinator, stack: DataStack = .shared) {
        self.coordinator = coordinator
        self.model = SettingsModel(coordinator: coordinator)
        self.stack = stack
        super.init()
    }

    /// Opens the window if anything required is missing.
    ///
    /// Called at launch. Returns whether it opened, so the caller can tell the
    /// difference between "shown the user their problem" and "nothing to do".
    ///
    /// Lands on Permissions rather than History: this path only runs when the
    /// app cannot dictate at all, and dropping the user on an empty history
    /// would make them hunt for the reason they were interrupted.
    @discardableResult
    func showIfNeeded() -> Bool {
        // Readiness is checked as well as the permission panes because the two
        // can disagree: `IOHIDCheckAccess` reporting granted does not mean the
        // tap armed for *this* copy of the binary.
        let blocked = !PermissionChecker.status().canDictate
            || coordinator.readiness == .needsPermission
        guard blocked else { return false }
        show(pane: .permissions)
        return true
    }

    /// Opens the window, optionally jumping to a pane.
    ///
    /// With no pane it opens wherever it was left. Forcing it back to a default
    /// on every open throws away the user's place for no reason; only a specific
    /// problem earns a jump.
    func show(pane: LibraryPane? = nil) {
        if let pane { model.pane = pane }

        if let window {
            model.startPolling()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Voice"
        window.titlebarAppearsTransparent = true
        window.minSize = Self.minimumSize
        window.delegate = self
        // Otherwise closing the window deallocates it out from under us and the
        // next open crashes rather than reusing it.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LibraryView(
                model: model,
                coordinator: coordinator,
                isHistoryEphemeral: stack.isEphemeral
            )
                .modelContainer(stack.container)
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
