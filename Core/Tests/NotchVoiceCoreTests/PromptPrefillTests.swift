import Testing
@testable import NotchVoiceCore

@Suite("PromptPrefill")
struct PromptPrefillTests {

    // Whisper's ids for large-v3, as the decoder sees them. Only their roles
    // matter: where the prompt starts, and the last token of the prefill.
    let startOfPrevious = 50362
    let startOfTranscript = 50258
    let english = 50259
    let transcribe = 50360
    let noTimestamps = 50364
    let endOfText = 50257

    /// `<|startofprev|> fetchUserProfile <|startoftranscript|><|en|><|transcribe|><|notimestamps|>`
    var prompted: [Int] {
        [startOfPrevious, 69, 7569, 52, 260, 12681, 794,
         startOfTranscript, english, transcribe, noTimestamps]
    }

    func awaiting(_ tokens: [Int]) -> Bool {
        PromptPrefill.isAwaitingFirstToken(
            tokens, startOfPrevious: startOfPrevious, lastPrefillToken: noTimestamps)
    }

    @Test("a prompted decode that has sampled nothing yet is still awaiting its first token")
    func promptedBeforeFirstToken() {
        // The regression: WhisperKit 0.x ended the decode on an end-of-text it
        // sampled here, while the prompt was still being forced in.
        #expect(awaiting(prompted))
    }

    @Test("once a word is sampled, the decode may end")
    func promptedAfterFirstToken() {
        // Holding end-of-text back past this point would let every biased
        // dictation run on to the token limit.
        #expect(!awaiting(prompted + [16852]))
        #expect(!awaiting(prompted + [16852, 13]))
    }

    @Test("an unprompted decode is never held")
    func unprompted() {
        #expect(!awaiting([startOfTranscript, english, transcribe, noTimestamps]))
        #expect(!awaiting([startOfTranscript, english, transcribe, noTimestamps, 16852]))
    }

    @Test("no tokens is not a prompted decode")
    func empty() {
        #expect(!awaiting([]))
    }
}
