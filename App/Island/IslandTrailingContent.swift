import SwiftUI
import NotchVoiceCore

/// The island's right wing: live audio while recording, a short word afterwards.
///
/// Its own view rather than a `@ViewBuilder` property on `IslandView`, so it
/// re-evaluates independently — a phase change that only affects this wing does
/// not invalidate the whole island.
///
/// Everything here is one word or one meter, because that is all the wing holds
/// — about 84pt of 11pt text at the widest. Anything with more to say goes to
/// `NotchPanelView` instead.
struct IslandTrailingContent: View {
    let phase: DictationCoordinator.Phase
    let levels: [Float]
    let inputTooQuiet: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch phase {
        case .dormant:
            EmptyView()

        case .recording, .locked:
            WaveformView(
                levels: levels,
                muted: inputTooQuiet,
                animates: !reduceMotion
            )

        case .transcribing, .polishing:
            // Same view, still fed the same levels — the coordinator stops
            // updating them at the end of a take instead of clearing them, so
            // the meter holds its last frame and fades rather than emptying.
            WaveformView(
                levels: levels,
                muted: inputTooQuiet,
                dimmed: true,
                animates: !reduceMotion
            )

        case .done:
            label("Done", .white)

        case .copied:
            // What to do, not what happened: nothing reached the cursor and the
            // text is sitting on the clipboard waiting to be pasted by hand.
            label("⌘V", .white)

        case .tooShort:
            label("Short", .white.opacity(0.65))

        case let .error(failure):
            label(failure.short, .orange)
        }
    }

    private func label(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            // Small type wants slightly positive tracking; a single fixed value
            // across every size would be wrong somewhere, and at 11pt on black
            // the default reads cramped.
            .tracking(0.15)
            .foregroundStyle(tint)
            .lineLimit(1)
            .allowsTightening(true)
            .truncationMode(.tail)
            .transition(.opacity.animation(.smooth(duration: 0.2)))
            .id(text)
    }
}
