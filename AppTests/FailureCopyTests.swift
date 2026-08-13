import Testing
import AppKit
import NotchVoiceCore
@testable import NotchVoice

/// `DictationFailure` is deliberately not `CaseIterable` — `Phase.error` carries
/// it as an associated value and nothing in the app enumerates it. Listed here
/// so a new case has to be added consciously rather than going untested.
///
/// File scope rather than a static on the suite: `@Test(arguments:)` is
/// evaluated outside the actor, so a `@MainActor` type cannot hold it.
let allDictationFailures: [DictationFailure] = [
    .noMicrophone, .silent, .modelLoading, .transcriptionFailed,
]

/// `DictationFailure` exists because the island's wing silently truncates
/// anything too long — "Nothing heard" rendered as "Nothi…". These measure the
/// copy against the space it is actually given, which is the only way that stays
/// true as either side changes.
@MainActor
@Suite("Failure copy")
struct FailureCopyTests {

    /// Matches `IslandTrailingContent`'s label.
    private static let islandFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func width(_ text: String) -> CGFloat {
        (text as NSString)
            .size(withAttributes: [.font: Self.islandFont])
            .width
    }

    @Test("every short label fits the island's widest wing", arguments: allDictationFailures)
    func shortFitsTheWing(_ failure: DictationFailure) {
        let available = IslandMetrics.contentWidth(inWing: IslandMetrics.messageTrailingWing)
        let needed = width(failure.short)
        #expect(
            needed <= available,
            "\"\(failure.short)\" needs \(needed)pt but the wing offers \(available)pt"
        )
    }

    @Test("every failure says what to do, not just that it broke", arguments: allDictationFailures)
    func messageIsActionable(_ failure: DictationFailure) {
        #expect(!failure.short.isEmpty)
        #expect(!failure.message.isEmpty)
        // A message is one line in the panel. Past this it wraps or clips, and
        // the panel exists precisely so nothing has to.
        #expect(failure.message.count <= 90, "message is \(failure.message.count) characters")
        // "Something went wrong" is an apology, not a message.
        #expect(failure.message != failure.short)
    }

    @Test("no two failures read the same")
    func failuresAreDistinguishable() {
        let shorts = allDictationFailures.map(\.short)
        let messages = allDictationFailures.map(\.message)
        #expect(Set(shorts).count == shorts.count, "two failures share a short label")
        #expect(Set(messages).count == messages.count, "two failures share a message")
    }
}

/// The panel is the only surface with room for a sentence, so any phase that
/// cannot be understood from one word has to supply one.
@MainActor
@Suite("Phase messages")
struct PhaseMessageTests {

    @Test("phases the user has to act on explain themselves")
    func actionablePhasesHaveAPanelMessage() {
        // `.copied` means nothing was pasted and the text is on the clipboard —
        // the one outcome where saying only "Copied" would leave the user
        // staring at an unchanged document.
        #expect(DictationCoordinator.Phase.copied.panelMessage != nil)
        #expect(DictationCoordinator.Phase.tooShort.panelMessage != nil)
        #expect(DictationCoordinator.Phase.error(.silent).panelMessage != nil)
    }

    @Test("phases that are just progress stay quiet")
    func transientPhasesHaveNoPanel() {
        for phase in [DictationCoordinator.Phase.dormant, .recording, .locked,
                      .transcribing, .polishing, .done] {
            #expect(phase.panelMessage == nil, "\(phase) should not open the panel")
        }
    }

    @Test("an error's panel message is its failure's message")
    func errorPanelUsesTheFailureCopy() {
        for failure in allDictationFailures {
            #expect(DictationCoordinator.Phase.error(failure).panelMessage == failure.message)
        }
    }
}
