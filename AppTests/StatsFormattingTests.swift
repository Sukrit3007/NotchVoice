import Testing
import Foundation
@testable import NotchVoice

/// The Stats pane's job is to be true. A figure that rounds a real value down to
/// zero is not a rounding — it is the pane saying nothing happened.
@MainActor
@Suite("Stats formatting")
struct StatsFormattingTests {

    @Test("under a minute of speech never reads as zero")
    func shortDurationsKeepSeconds() {
        // The bug this replaced: a fixed [.hours, .minutes] rendered 25 seconds
        // of speech as "0 min" — right next to a words count that was not zero.
        for seconds in [1.0, 25.0, 59.0] {
            let text = StatsPane.spoken(seconds)
            #expect(!text.hasPrefix("0"), "\(seconds)s rendered as \"\(text)\"")
        }
    }

    @Test("units step up with magnitude", arguments: [
        (30.0, "sec"),
        (600.0, "min"),
        (7200.0, "hr"),
    ])
    func unitsMatchMagnitude(_ seconds: Double, _ expectedUnit: String) {
        #expect(StatsPane.spoken(seconds).contains(expectedUnit))
    }

    @Test("a real duration is never empty")
    func alwaysRenders() {
        for seconds in [0.0, 0.5, 59.9, 60.0, 3599.0, 3600.0, 86_400.0] {
            #expect(!StatsPane.spoken(seconds).isEmpty)
        }
    }
}
