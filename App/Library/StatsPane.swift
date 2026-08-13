import SwiftUI
import SwiftData

/// What the app has done for you, in the numbers that are actually true.
///
/// Uses `@Query` rather than `CaptureStore.totals()` so the figures move as
/// dictations land. Both go through `CaptureTotals.of`, so there is one
/// implementation of the arithmetic and the pane cannot disagree with the store.
@MainActor
struct StatsPane: View {
    @Query private var captures: [Capture]

    private var totals: CaptureTotals { .of(captures) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Dictations", value: totals.captures, format: .number)
                LabeledContent("Words", value: totals.words, format: .number)
                LabeledContent("Time spoken") {
                    Text(Self.spoken(totals.seconds))
                }
            }

            Section {
                LabeledContent("Speaking rate") {
                    // Nil rather than zero before there is anything to average.
                    // "0 wpm" is a claim about the user; an em dash is an
                    // absence of data, and they are not the same statement.
                    if let wpm = totals.wordsPerMinute {
                        Text("\(Int(wpm.rounded())) words per minute")
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Typing saved") {
                    if let saved = typingSaved {
                        Text(saved, format: .units(allowed: [.hours, .minutes], width: .wide))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Compared with typing at \(Self.typingWordsPerMinute) words per minute.")
            }

            if !topApps.isEmpty {
                Section("Where it goes") {
                    ForEach(topApps, id: \.name) { app in
                        LabeledContent(app.name, value: app.count, format: .number)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .monospacedDigit()
    }

    /// Units chosen by magnitude rather than fixed.
    ///
    /// A fixed `[.hours, .minutes]` renders half a minute of speech as "0 min",
    /// which is not a rounding — it is the pane stating nothing was said. The
    /// same mistake as printing "0 wpm" before there is anything to average.
    static func spoken(_ seconds: Double) -> String {
        let allowed: Set<Duration.UnitsFormatStyle.Unit> =
            switch seconds {
            case ..<60: [.seconds]
            case ..<3600: [.minutes]
            default: [.hours, .minutes]
            }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: allowed, width: .abbreviated))
    }

    /// An average office typing speed. Stated in the footer rather than baked
    /// into a number the user cannot question — a "time saved" figure with no
    /// visible assumption behind it is marketing, not a stat.
    private static let typingWordsPerMinute = 40

    private var typingSaved: Duration? {
        guard totals.words > 0 else { return nil }
        let typingSeconds = Double(totals.words) / Double(Self.typingWordsPerMinute) * 60
        let saved = typingSeconds - totals.seconds
        guard saved > 60 else { return nil }
        return .seconds(saved)
    }

    private var topApps: [(name: String, count: Int)] {
        Dictionary(grouping: captures.compactMap(\.targetAppName), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(5)
            .map { $0 }
    }
}
