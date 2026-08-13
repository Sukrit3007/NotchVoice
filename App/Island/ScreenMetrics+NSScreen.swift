import AppKit
import NotchVoiceCore

extension NSScreen {
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frameWidth: frame.width,
            frameHeight: frame.height,
            originX: frame.origin.x,
            originY: frame.origin.y,
            safeAreaTop: safeAreaInsets.top,
            auxiliaryLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryRightWidth: auxiliaryTopRightArea?.width ?? 0
        )
    }

    /// The screen the pointer is currently on, falling back to the main screen.
    static var active: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
