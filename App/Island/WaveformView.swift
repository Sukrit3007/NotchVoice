import SwiftUI
import NotchVoiceCore

/// Live microphone amplitude, oldest bar on the left.
///
/// Deliberately no timer — the bars themselves answer "is it hearing me?",
/// which is the only question the recording state needs to answer. Every
/// dimension comes from `IslandMetrics`, where a Core test asserts the bars fit
/// the wing that holds them.
///
/// The bars are drawn at full height and **scaled**, never resized. A capsule
/// whose `frame(height:)` changes forces a layout pass on every level callback,
/// ten times a second, for the whole recording; `scaleEffect` is handled by the
/// compositor and touches no layout at all. Same picture, none of the work.
struct WaveformView: View {
    let levels: [Float]

    /// Dims the bars when the input is too quiet to transcribe, so a failing
    /// take does not look like a working one that happens to be paused.
    var muted: Bool = false

    /// Fades the meter while the transcript is being decoded.
    ///
    /// The bars are not cleared at the end of a take — they hold their last
    /// frame and dim. A meter that emptied itself would read as "stopped
    /// listening and lost it"; one that freezes reads as "heard you, thinking",
    /// and it keeps the right wing occupied so the island does not lurch
    /// sideways between recording and transcribing.
    var dimmed: Bool = false

    /// False under Reduce Motion: the bars still update, they just jump to the
    /// new value instead of tweening.
    var animates: Bool = true

    private let barWidth = IslandMetrics.waveformBarWidth
    private let barSpacing = IslandMetrics.waveformBarSpacing

    /// Full height of a bar. Scaling happens against this.
    private let barHeight: CGFloat = 16

    /// Scale at silence. Never zero: at this value the capsule is as tall as it
    /// is wide, so it renders as a dot — a flat row of dots still says
    /// "listening, hearing nothing", which is a different message from an empty
    /// box.
    private var minScale: CGFloat { barWidth / barHeight }

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            // Keyed by position, not by value: the levels array is a fixed-size
            // ring where each slot is one bar over time. Identifying bars by
            // value would insert and remove bars every frame.
            //
            // No `Array(…)` around the sequence — `enumerated()` is itself a
            // collection as of Swift 6.2, and wrapping it allocates a fresh
            // array on every level callback, twenty times a second, in the one
            // view written specifically to avoid per-frame work.
            ForEach(levels.enumerated(), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(muted ? Color.orange.opacity(0.55) : .white)
                    .frame(width: barWidth, height: barHeight)
                    .scaleEffect(
                        x: 1,
                        y: minScale + CGFloat(level) * (1 - minScale),
                        anchor: .center
                    )
            }
        }
        .frame(height: barHeight)
        // Never let a parent squeeze the bars. The meter's width is a fact Core
        // asserts against the wing holding it, and a frame that compressed it
        // here would break that guarantee silently.
        .fixedSize(horizontal: true, vertical: false)
        .opacity(dimmed ? 0.4 : 1)
        // Matched to how fast levels actually arrive, not how fast they were
        // requested: `MicRecorder` asks for 20/sec but `bufferSize` is only a
        // request and CoreAudio returns ~100ms buffers. Anything shorter than
        // 0.1 makes each bar move then sit frozen — visible stepping. If
        // CoreAudio ever honours the ask, these two numbers move together.
        .animation(animates ? .linear(duration: 0.1) : nil, value: levels)
        .animation(animates ? .smooth(duration: 0.25) : nil, value: muted)
        .animation(animates ? .smooth(duration: 0.3) : nil, value: dimmed)
        // Purely decorative. Seven bars announced individually would be noise,
        // and what they mean — recording, hearing you — is carried by the
        // island's own label instead.
        .accessibilityHidden(true)
    }
}
