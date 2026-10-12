import Foundation

/// Where a prompted Whisper decode is: still being fed its prompt, or
/// producing tokens of its own.
///
/// A decode conditioned on a bias prompt starts with a fixed run of tokens it
/// is *given*, not ones it chooses:
///
///     <|startofprev|> custom words, screen text <|startoftranscript|><|en|><|transcribe|><|notimestamps|>
///
/// WhisperKit 0.x feeds that run in one token per step and samples a token at
/// every step, then throws the sample away. Except an end-of-text: that one it
/// honours, and the decode stops before a single word is heard — an empty
/// transcript for a dictation that was spoken (argmax-oss-swift #501, fixed
/// upstream in 1.1.0). The host suppresses end-of-text while this says
/// the decode is still awaiting its first token.
///
/// That window includes the first real step, which the decoder's sampling
/// cannot tell apart from the prompt. Holding end-of-text there too is what
/// reference Whisper does by default (`suppress_blank`): no transcript may end
/// before it has started.
///
/// Pure: the host supplies the tokenizer's ids.
public enum PromptPrefill {

    /// True while a prompted decode has produced nothing of its own.
    ///
    /// - Parameters:
    ///   - tokens: Everything the decoder holds so far, prompt included.
    ///   - startOfPrevious: `<|startofprev|>`, which opens a prompt.
    ///   - lastPrefillToken: The token the prefill ends on —
    ///     `<|notimestamps|>` when decoding without timestamps.
    public static func isAwaitingFirstToken(
        _ tokens: [Int], startOfPrevious: Int, lastPrefillToken: Int
    ) -> Bool {
        // Unprompted decodes start at <|startoftranscript|> and never hit the
        // bug. A prompted one's tokens stop ending on the prefill token the
        // moment it samples its first word.
        tokens.first == startOfPrevious && tokens.last == lastPrefillToken
    }
}
