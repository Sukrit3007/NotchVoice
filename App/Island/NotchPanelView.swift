import SwiftUI

/// A sentence, hanging below the notch.
///
/// The island's wings hold one word, and there is no failure cue — so a
/// dictation that fails makes no sound at all and text is the only channel left.
/// "Silent" in orange is not an explanation of anything.
///
/// It drops out of the notch and returns the same way rather than fading in
/// place, so it reads as the island having more to say instead of as an
/// unrelated notification that appeared at the same moment.
///
/// **This is the vertical axis `IslandView` is forbidden from using.** The span
/// below the cutout belongs to content; anything else needing it should reuse
/// this shape rather than inventing a second one.
struct NotchPanelView: View {
    let message: String

    /// Wide enough for a two-line sentence at the default text size, narrow
    /// enough to stay visually attached to the notch above it. Not a hard frame:
    /// the text wraps and the panel grows downward when the user's text size is
    /// larger, which is the axis there is room on.
    private static let maxWidth: CGFloat = 300

    var body: some View {
        Text(message)
            // Dynamic Type, unlike the island above it. The island is pinned to
            // the physical cutout and genuinely cannot grow; this is on real
            // screen with 200pt of window beneath it, so there is no excuse for
            // a fixed size here.
            .font(.callout)
            .foregroundStyle(.white.opacity(0.92))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: Self.maxWidth)
            .background(.black, in: .rect(cornerRadius: 18))
            // Read as one statement rather than as loose text in a container.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
            .onAppear(perform: announce)
    }

    /// Speaks the message when it appears.
    ///
    /// Load-bearing for VoiceOver, not a nicety. This panel lives in a
    /// borderless overlay window that never takes focus, so nothing moves
    /// VoiceOver's cursor here and the label alone would never be read. With no
    /// failure sound either, an unannounced panel means a failed dictation is
    /// silent *and* invisible.
    private func announce() {
        AccessibilityNotification.Announcement(message).post()
    }
}

#Preview("Didn't hear anything") {
    NotchPanelView(message: DictationFailure.silent.message)
        .padding(40)
        .background(.gray)
}

#Preview("Copied") {
    NotchPanelView(message: "Text copied. Press ⌘V to paste it where you want it.")
        .padding(40)
        .background(.gray)
}

#Preview("Every failure") {
    VStack(spacing: 12) {
        NotchPanelView(message: DictationFailure.noMicrophone.message)
        NotchPanelView(message: DictationFailure.silent.message)
        NotchPanelView(message: DictationFailure.modelLoading.message)
        NotchPanelView(message: DictationFailure.transcriptionFailed.message)
    }
    .padding(40)
    .background(.gray)
}
