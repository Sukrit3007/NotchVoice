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
        setVisible(for: coordinator.phase)
    }

    /// Retain the overlay for fast transitions, but keep the normal MacBook
    /// notch untouched while the app is idle.
    func setVisible(for phase: DictationCoordinator.Phase) {
        guard let window else { return }
        if phase == .dormant {
            window.orderOut(nil)
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
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

        let metrics = screen.metrics
        // Derived from NotchGeometry.notchRect rather than assumed to be zero:
        // that function takes the cutout's left edge from the auxiliary area
        // instead of the frame centre, which is the whole point of the task 5
        // fix. Reading midX back out keeps the view honest about the same rule.
        let notchOffset = NotchGeometry.notchRect(for: metrics)
            .map { $0.midX - screen.frame.midX } ?? 0

        // External displays borrow the laptop's dimensions for consistent HUD
        // spacing, but IslandView renders a compact HUD there rather than a
        // fake cutout.
        let notch = NotchGeometry.effectiveNotch(
            for: metrics,
            among: NSScreen.screens.map(\.metrics)
        )

        // Logged because every layout argument about this app has so far been
        // conducted against a 16" test fixture rather than the machine it is
        // running on. The wings are sized in points and the cutout is not, so
        // the only honest way to reason about whether content clears an edge is
        // to know what the cutout actually measures here — and, now, whether it
        // is a hole in the display or one this app drew.
        let islandWidth = IslandMetrics.islandWidth(
            notchWidth: notch.size.width,
            leadingWing: IslandMetrics.expandedLeadingWing,
            trailingWing: IslandMetrics.waveformTrailingWing)
        Log.island.info("""
            Screen \(screen.frame.width, privacy: .public)x\(screen.frame.height, privacy: .public), \
            notch \(notch.size.width, privacy: .public)x\(notch.size.height, privacy: .public) \
            (\(notch.isPhysical ? "physical" : "drawn", privacy: .public)), \
            island \(islandWidth, privacy: .public)
            """)

        let window = IslandWindow(contentRect: frame)
        let root = IslandView(
            coordinator: coordinator,
            notchSize: notch.size,
            isPhysical: notch.isPhysical,
            notchCenterOffset: notchOffset
        )
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(frame, display: true)
        if coordinator.phase != .dormant {
            window.orderFrontRegardless()
        }

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
        setVisible(for: coordinator.phase)
    }
}
