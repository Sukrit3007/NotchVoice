import CoreGraphics

/// The subset of `NSScreen` this module needs, lifted into a plain value so
/// the geometry rules can be tested without a display attached.
public struct ScreenMetrics: Equatable, Sendable {
    public let frameWidth: CGFloat
    public let frameHeight: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    /// `NSScreen.safeAreaInsets.top`.
    public let safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea?.width ?? 0`.
    public let auxiliaryLeftWidth: CGFloat
    /// `NSScreen.auxiliaryTopRightArea?.width ?? 0`.
    public let auxiliaryRightWidth: CGFloat

    public init(
        frameWidth: CGFloat,
        frameHeight: CGFloat,
        originX: CGFloat,
        originY: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat,
        auxiliaryRightWidth: CGFloat
    ) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.originX = originX
        self.originY = originY
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
    }
}

/// Derives the physical notch cutout from screen metrics.
///
/// A top safe-area inset alone is not enough — a full-screen menu bar produces
/// one too. Both auxiliary top areas must be non-zero, because those are the
/// usable strips either side of the cutout and they only exist when there is
/// a cutout between them.
public enum NotchGeometry {

    public static func notchSize(for metrics: ScreenMetrics) -> CGSize? {
        guard metrics.safeAreaTop > 0 else { return nil }
        guard metrics.auxiliaryLeftWidth > 0, metrics.auxiliaryRightWidth > 0 else {
            return nil
        }
        let width = metrics.frameWidth
            - metrics.auxiliaryLeftWidth
            - metrics.auxiliaryRightWidth
        guard width > 0 else { return nil }
        return CGSize(width: width, height: metrics.safeAreaTop)
    }

    /// Notch rect in screen coordinates, origin bottom-left as AppKit expects.
    ///
    /// The x origin is the left auxiliary area's width — that's the cutout's
    /// actual left edge, not an assumed centre. The cutout is not guaranteed
    /// to be centred in the frame.
    public static func notchRect(for metrics: ScreenMetrics) -> CGRect? {
        guard let size = notchSize(for: metrics) else { return nil }
        return CGRect(
            x: metrics.originX + metrics.auxiliaryLeftWidth,
            y: metrics.originY + metrics.frameHeight - size.height,
            width: size.width,
            height: size.height
        )
    }
}
