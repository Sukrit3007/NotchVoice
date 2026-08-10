import Testing
import CoreGraphics
@testable import NotchVoiceCore

@Suite("NotchGeometry")
struct NotchGeometryTests {

    /// 16" MacBook Pro in points.
    private var macBookPro: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 0, originY: 0,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 764, auxiliaryRightWidth: 764
        )
    }

    /// External monitor: no safe-area inset, no auxiliary areas.
    private var externalMonitor: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 2560, frameHeight: 1440,
            originX: 1728, originY: 0,
            safeAreaTop: 0,
            auxiliaryLeftWidth: 0, auxiliaryRightWidth: 0
        )
    }

    @Test("a notched screen reports the notch size")
    func notchedScreenHasSize() {
        let size = NotchGeometry.notchSize(for: macBookPro)
        #expect(size == CGSize(width: 200, height: 32))
    }

    @Test("an external monitor reports no notch")
    func externalMonitorHasNoNotch() {
        #expect(NotchGeometry.notchSize(for: externalMonitor) == nil)
    }

    @Test("a screen with a top inset but no auxiliary areas has no notch")
    func insetWithoutAuxiliaryAreasIsNotANotch() {
        // A full-screen-menu-bar inset is not a notch. Both auxiliary areas
        // must be present for the cutout to be real.
        let metrics = ScreenMetrics(
            frameWidth: 1920, frameHeight: 1080,
            originX: 0, originY: 0,
            safeAreaTop: 24,
            auxiliaryLeftWidth: 0, auxiliaryRightWidth: 0
        )
        #expect(NotchGeometry.notchSize(for: metrics) == nil)
    }

    @Test("the notch rect is centred at the top of the screen")
    func notchRectIsTopCentred() {
        let rect = NotchGeometry.notchRect(for: macBookPro)
        #expect(rect == CGRect(x: 764, y: 1085, width: 200, height: 32))
    }

    @Test("the notch rect accounts for a non-zero screen origin")
    func notchRectRespectsOrigin() {
        let metrics = ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 100, originY: 50,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 764, auxiliaryRightWidth: 764
        )
        let rect = NotchGeometry.notchRect(for: metrics)
        #expect(rect == CGRect(x: 864, y: 1135, width: 200, height: 32))
    }

    @Test("an external monitor has no notch rect")
    func externalMonitorHasNoRect() {
        #expect(NotchGeometry.notchRect(for: externalMonitor) == nil)
    }

    @Test("the notch rect uses the left auxiliary edge, not the frame centre")
    func notchRectUsesLeftAuxiliaryEdgeNotCentre() {
        // Asymmetric auxiliary areas: centring logic would return x = 764 here.
        let metrics = ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 0, originY: 0,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 700, auxiliaryRightWidth: 828
        )
        let rect = NotchGeometry.notchRect(for: metrics)
        #expect(rect == CGRect(x: 700, y: 1085, width: 200, height: 32))
    }
}
