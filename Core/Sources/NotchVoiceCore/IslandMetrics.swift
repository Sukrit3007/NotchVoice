import CoreGraphics

/// Widths for the island's wings, and the rule that turns them into an overall
/// island width.
///
/// Lives in Core so the fit can be asserted: a view cannot test that its
/// contents fit the space it was given, and `IslandMetricsTests` can.
///
/// The island is **never** taller than the cutout and never grows downward.
/// That span is reserved for the transcript panel; horizontal is status,
/// vertical is content, and nothing here may take the vertical axis.
public enum IslandMetrics {

    /// Gap between a wing's outer edge and its content.
    ///
    /// One edge, not two: the wing's inner edge butts against the cutout, and
    /// padding there would push content further under a hole in the display.
    public static let wingPadding: CGFloat = 12

    // MARK: - Wings

    /// Left wing at rest.
    ///
    /// Deliberately small. The island draws above the menu bar, and the strip
    /// immediately left of the cutout is where app menu titles run out to. At
    /// this width it clears the menus of ordinary apps; an app with a very wide
    /// menu bar can still be clipped, which is the accepted cost of a resting
    /// indicator.
    public static let idleLeadingWing: CGFloat = 26

    /// Left wing while a dictation is in flight. Holds one SF Symbol at 12pt.
    public static let expandedLeadingWing: CGFloat = 36

    /// Right wing carrying the live meter.
    ///
    /// The trailing wing has a budget the leading one does not: it grows into
    /// the strip where menu bar extras live, and those fill leftward from the
    /// screen edge. Widening this is not free — it is spent against whatever the
    /// user keeps in their menu bar.
    public static let waveformTrailingWing: CGFloat = 44

    /// Right wing carrying a short word — "Done", "Short", "⌘V".
    public static let labelTrailingWing: CGFloat = 48

    /// Right wing carrying a short sentence — "Nothing heard".
    ///
    /// Wider than the others on purpose. The island resizes per state, so the
    /// one state that has something to say is allowed to be the widest rather
    /// than forcing every state to carry its width.
    public static let messageTrailingWing: CGFloat = 60

    // MARK: - Waveform

    /// Bars in the meter.
    ///
    /// Bar count follows the wing budget, not the other way round — more bars
    /// means a wider wing, and that width comes out of the menu bar extras.
    /// `IslandMetricsTests` pins the relationship, so raising this fails a test
    /// instead of clipping on hardware.
    public static let waveformBarCount = 7
    public static let waveformBarWidth: CGFloat = 2.5
    public static let waveformBarSpacing: CGFloat = 2

    /// Total width the bars occupy: n bars and n-1 gaps.
    public static var waveformContentWidth: CGFloat {
        CGFloat(waveformBarCount) * waveformBarWidth
            + CGFloat(waveformBarCount - 1) * waveformBarSpacing
    }

    // MARK: - Derivation

    /// Space available to a wing's contents.
    public static func contentWidth(inWing wing: CGFloat) -> CGFloat {
        max(0, wing - wingPadding)
    }

    /// Overall island width for a given pair of wings.
    ///
    /// Derived, never stored. Wings are chosen to fit what they carry, and the
    /// island is whatever that adds up to — sizing the other way round makes the
    /// two sides equal by construction and hides a wing that does not fit.
    public static func islandWidth(
        notchWidth: CGFloat,
        leadingWing: CGFloat,
        trailingWing: CGFloat
    ) -> CGFloat {
        notchWidth + leadingWing + trailingWing
    }
}
