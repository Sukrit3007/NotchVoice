import AppKit
import SwiftUI

/// Owns the first-run window.
///
/// A fixed-size, non-resizable window on purpose: the flow is a sequence of
/// short screens, and a resizable one invites a user to drag it wide and find
/// the layout has nothing to fill the space with.
///
/// The activation policy is switched to `.regular` while this is open, unlike
/// the library window. The permission steps send the user to System Settings and
/// back, and an accessory app with no Dock icon gives them nothing to click to
/// return to — leaving them in System Settings wondering what was supposed to
/// happen next.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private let model: OnboardingModel
    private var onFinish: (() -> Void)?

    init(coordinator: DictationCoordinator) {
        self.model = OnboardingModel(coordinator: coordinator)
        super.init()
    }

    func show(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Notch Voice"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: OnboardingView(model: model) { [weak self] in self?.complete() }
        )
        window.center()

        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func complete() {
        model.finish()
        close()
    }

    private func close() {
        window?.close()
        window = nil
        // Back to a background app. Done here rather than in `windowWillClose`
        // so it happens exactly once, whichever way the window went away.
        NSApp.setActivationPolicy(.accessory)
        onFinish?()
        onFinish = nil
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing the window without finishing is not completing the flow —
        // `OnboardingPreference` stays false and the user is offered it again
        // next launch. Quitting halfway through granting permissions should not
        // count as having been onboarded.
        model.stopPolling()
        guard window != nil else { return }
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onFinish?()
        onFinish = nil
    }
}
