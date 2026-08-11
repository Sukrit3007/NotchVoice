import AppKit
import SwiftUI
import NotchVoiceCore

/// Owns the island window and keeps it on the screen the user is working on.
@MainActor
final class IslandWindowController {

    /// Tall enough for the expanded island plus its drop shadow.
    private static let stripHeight: CGFloat = 200

    private var window: IslandWindow?
    private let coordinator: DictationCoordinator
    private var screenObserver: NSObjectProtocol?

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator
    }

    /// `isolated` for the same reason `ModifierTap`'s is: a nonisolated deinit
    /// cannot touch `screenObserver` at all, because `NSObjectProtocol` is not
    /// Sendable and Swift 6 rejects reading it from there.
    isolated deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func show() {
        buildWindow(on: NSScreen.active)
        observeScreenChanges()
    }

    /// Rebuilds on the screen the pointer is on. Cheap enough to call on every
    /// dictation start, which is how the island follows the user between
    /// displays without polling.
    func moveToActiveScreen() {
        guard let screen = NSScreen.active else { return }
        guard window?.screen != screen else { return }
        buildWindow(on: screen)
    }

    private func buildWindow(on screen: NSScreen?) {
        guard let screen else { return }

        window?.orderOut(nil)
        window = nil

        let frame = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - Self.stripHeight,
            width: screen.frame.width,
            height: Self.stripHeight
        )

        let window = IslandWindow(contentRect: frame)
        let root = IslandView(
            coordinator: coordinator,
            notchSize: NotchGeometry.notchSize(for: screen.metrics)
        )
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()

        self.window = window
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildForScreenChange()
            }
        }
    }

    /// Rebuilt wholesale rather than resized: a screen-parameter change can
    /// alter the notch geometry the view was built with, and that is passed in
    /// at construction.
    func rebuildForScreenChange() {
        buildWindow(on: NSScreen.active)
    }
}
