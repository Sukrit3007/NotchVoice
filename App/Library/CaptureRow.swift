import SwiftUI

/// One transcript in the history list.
///
/// The text leads and the metadata follows, because the transcript is the thing
/// being scanned for — where it went and how long it took only matter once the
/// right row has been found.
@MainActor
struct CaptureRow: View {
    let capture: Capture

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Aligned to the first line of the transcript rather than centred on
            // the row, so a three-line transcript does not push it to the middle.
            AppIconView(bundleID: capture.targetBundleID)
                .padding(.top, 1)

            content
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(capture.text)
                .lineLimit(3)
                // Body weight and size; the metadata below is what recedes.
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(capture.createdAt, format: .dateTime.hour().minute())

                if let app = capture.targetAppName {
                    separator
                    Text(app)
                } else {
                    // Not silence — this row went to the clipboard because the
                    // paste was never consumed, and that is worth being able to
                    // spot when several of them cluster in one app.
                    separator
                    Text("Clipboard")
                }

                separator
                // Tabular so the numbers line up down the column instead of
                // jittering as the digit widths change.
                Text("\(capture.wordCount) words")
                    .monospacedDigit()

                if capture.wasPolished {
                    separator
                    Text("Tidied")
                        .help("The transcript was cleaned up before it was pasted")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var separator: some View {
        Text("·").foregroundStyle(.tertiary)
    }
}
