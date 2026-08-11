import AppKit

/// Transparent borderless window that hosts the island.
///
/// Sits above the menu bar (`.statusBar + 1`) so it can cover the notch, joins
/// every Space, and stays put during Mission Control. It never takes key focus
/// — doing so would yank focus out of whatever the user is dictating into,
/// which is the opposite of what an overlay should do.
final class IslandWindow: NSWindow {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        // The island is a readout, not a control. Letting it eat clicks would
        // put a dead strip across the top of every screen.
        ignoresMouseEvents = true
        level = .statusBar + 1
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
