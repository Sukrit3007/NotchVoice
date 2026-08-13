import Testing
import CoreGraphics
@testable import NotchVoiceCore

@Suite("IslandMetrics")
struct IslandMetricsTests {

    /// 14" MacBook Pro — read off the machine this runs on, not assumed.
    ///
    /// `NotchGeometryTests` models a 16", and taking its 200pt cutout as "the"
    /// notch width is how the wings got resized in the wrong direction. The
    /// two sizes differ and the layout has to hold on both, so both appear
    /// here rather than one standing in for the other.
    private var macBookPro14: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 1512, frameHeight: 982,
            originX: 0, originY: 0,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5
        )
    }

    /// 16" MacBook Pro, matching `NotchGeometryTests`.
    private var macBookPro16: ScreenMetrics {
        ScreenMetrics(
            frameWidth: 1728, frameHeight: 1117,
            originX: 0, originY: 0,
            safeAreaTop: 32,
            auxiliaryLeftWidth: 764, auxiliaryRightWidth: 764
        )
    }

    private var notchWidth: CGFloat {
        NotchGeometry.notchSize(for: macBookPro14)!.width
    }

    // MARK: - The overflow this type exists to prevent

    @Test("the waveform fits inside its wing")
    func waveformFitsItsWing() {
        let available = IslandMetrics.contentWidth(inWing: IslandMetrics.waveformTrailingWing)
        #expect(IslandMetrics.waveformContentWidth <= available)
    }

    @Test("the margin beside content is the padding, not leftover wing space")
    func paddingIsTheVisibleMargin() {
        // The meter is trailing-aligned, so any spare width inside the wing
        // falls on the cutout side and adds nothing to the visible gap at the
        // island's edge. That gap is `wingPadding` and only `wingPadding` —
        // which is why the fix for "the icon looks flush against the edge" was
        // to raise this number rather than to widen the wing.
        #expect(IslandMetrics.wingPadding >= 12)
    }

    @Test("the old halve-the-remainder rule broke on a 16-inch cutout")
    func historicalLayoutWasNotPortable() {
        // What shipped before: a hardcoded 270pt island with the wings derived
        // by halving whatever the cutout left over. On the 14" it developed on
        // that gave 42.5pt wings and the meter fitted. On a 16", whose cutout
        // is 15pt wider, the same formula yields 35pt and the bars overflow.
        // The bug was never the numbers — it was deriving a wing from a total
        // instead of from its contents.
        let oldIslandWidth: CGFloat = 270
        let oldPadding: CGFloat = 8
        let bars = CGFloat(7) * IslandMetrics.waveformBarWidth
            + CGFloat(6) * IslandMetrics.waveformBarSpacing

        let wing14 = (oldIslandWidth - NotchGeometry.notchSize(for: macBookPro14)!.width) / 2
        let wing16 = (oldIslandWidth - NotchGeometry.notchSize(for: macBookPro16)!.width) / 2

        #expect(wing14 == 42.5)
        #expect(wing16 == 35)
        #expect(bars <= wing14 - oldPadding)   // fitted here
        #expect(bars > wing16 - oldPadding)    // and not there
    }

    @Test("the island clears the menu bar extras on the measured machine")
    func islandStopsShortOfTheStatusItems() {
        // The cutout ends at x=848.5 on this display. Every trailing wing is
        // spent to the right of that, in the strip where menu bar extras live,
        // so the widest state is what determines whether the island collides
        // with them.
        let rect = NotchGeometry.notchRect(for: macBookPro14)!
        let widest = max(
            IslandMetrics.waveformTrailingWing,
            max(IslandMetrics.labelTrailingWing, IslandMetrics.messageTrailingWing)
        )
        #expect(rect.maxX == 848.5)
        #expect(rect.maxX + widest <= 910)
    }

    @Test("a short label fits inside its wing")
    func labelFitsItsWing() {
        // "Short" is the longest of the short labels; at 11pt medium it runs
        // to roughly 32pt. Checked against the slot rather than measured here,
        // because text measurement needs a font and Core has no AppKit.
        let available = IslandMetrics.contentWidth(inWing: IslandMetrics.labelTrailingWing)
        #expect(available >= 32)
    }

    @Test("the error wing holds a one-word message")
    func messageFitsItsWing() {
        // Core has no font, so this pins the budget rather than measuring
        // text: about 46pt at 11pt medium is seven characters. Error strings
        // in `DictationCoordinator` are written to that limit — "Silent",
        // "No mic", "Loading", "Failed" — because the alternative is a wing
        // wide enough for a sentence, spent into the menu bar extras for a
        // state that shows for four seconds.
        let available = IslandMetrics.contentWidth(inWing: IslandMetrics.messageTrailingWing)
        #expect(available >= 44)
    }

    // MARK: - Widths

    @Test("island width is the cutout plus both wings")
    func islandWidthSumsTheParts() {
        let width = IslandMetrics.islandWidth(
            notchWidth: notchWidth,
            leadingWing: IslandMetrics.expandedLeadingWing,
            trailingWing: IslandMetrics.waveformTrailingWing
        )
        let expected: CGFloat = 185 + 34 + 44
        #expect(width == expected)
    }

    @Test("the resting island carries a leading wing and no trailing one")
    func idleIslandHasOnlyALeadingWing() {
        let width = IslandMetrics.islandWidth(
            notchWidth: notchWidth,
            leadingWing: IslandMetrics.idleLeadingWing,
            trailingWing: 0
        )
        let expected: CGFloat = 185 + 26
        #expect(width == expected)
    }

    @Test("the wings are deliberately unequal")
    func wingsAreAsymmetric() {
        // A design rule, not an accident. The left wing holds a glyph and the
        // right holds a meter; sizing them together is what produced a pair
        // that fit neither.
        #expect(IslandMetrics.expandedLeadingWing != IslandMetrics.waveformTrailingWing)
    }

    @Test("the resting leading wing is narrower than the expanded one")
    func idleWingIsSmallerThanExpanded() {
        // The resting wing sits on top of the menu bar, so it is kept small.
        #expect(IslandMetrics.idleLeadingWing < IslandMetrics.expandedLeadingWing)
    }

    // MARK: - Content area

    @Test("content width takes one padding off the wing, not two")
    func contentWidthSubtractsOneEdge() {
        // The inner edge butts against the cutout; padding there would push
        // content under a hole in the display.
        #expect(IslandMetrics.contentWidth(inWing: 50) == 38)
    }

    @Test("a wing narrower than its padding reports no content space")
    func contentWidthNeverGoesNegative() {
        #expect(IslandMetrics.contentWidth(inWing: 4) == 0)
    }
}
