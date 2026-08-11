import SwiftUI

/// Live microphone amplitude as scrolling vertical bars.
///
/// Deliberately no timer — the bars themselves answer "is it hearing me?",
/// which is the only question the recording state needs to answer.
struct WaveformView: View {
    let levels: [Float]

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            // Identity is the slot, not the sample. The buffer shifts left on
            // every append, so each bar animates to its neighbour's old value
            // and the row reads as scrolling — which is the intent. Keying on
            // the value instead would insert and remove bars every frame.
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule(style: .continuous)
                    .fill(.white)
                    .frame(
                        width: barWidth,
                        height: minHeight + CGFloat(level) * (maxHeight - minHeight)
                    )
            }
        }
        .animation(.linear(duration: 0.05), value: levels)
    }
}
