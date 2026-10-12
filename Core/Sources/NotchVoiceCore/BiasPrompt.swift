import Foundation

/// Builds the conditioning prompt handed to the decoder before it transcribes.
///
/// Whisper accepts a prompt as *previous context* and biases its output toward
/// the vocabulary in it. That is the cheapest accuracy win available — it fixes
/// names and jargon at the point they are heard, rather than rewriting them
/// afterwards and hoping the mistake was the one that was predicted.
///
/// Two sources feed it, in falling order of confidence:
///
/// 1. **Custom words.** Terms the user has said are important.
/// 2. **On-screen context.** Text already in the field being dictated into,
///    which supplies the names and jargon of whatever they are actually working
///    on without anyone having to type a list.
///
/// The budget is what makes the order matter. Whisper's prompt shares a fixed
/// context window with the transcript, so an over-long prompt costs decoding
/// room. Custom words go in first and context fills whatever is left.
public enum BiasPrompt {

    /// Roughly half of Whisper's 448-token window, in characters at ~4 characters
    /// per token. A budget rather than a limit — going over does not fail, it
    /// silently eats the room the transcript needs.
    public static let characterBudget = 850

    /// Context is truncated to this before it is even considered, so one very
    /// long document cannot crowd out every custom word.
    public static let contextShare = 500

    public static func build(terms: [String], context: String? = nil) -> String? {
        let cleanTerms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var prompt = ""

        if !cleanTerms.isEmpty {
            // Comma-separated rather than a sentence. A prompt is read as prior
            // transcript, and a list of terms biases toward the terms without
            // also biasing toward a sentence shape the user did not use.
            prompt = truncated(cleanTerms.joined(separator: ", "), to: characterBudget)
        }

        if let context, !context.isEmpty {
            let remaining = characterBudget - prompt.count - 2
            if remaining > 40 {
                // Kept whole-word and taken from the **end**: the text nearest
                // the cursor is the text the next sentence continues from.
                let tail = tail(of: context, limit: min(remaining, contextShare))
                if !tail.isEmpty {
                    prompt += prompt.isEmpty ? tail : ". " + tail
                }
            }
        }

        return prompt.isEmpty ? nil : prompt
    }

    /// The prompt as the decoder should be handed it: with one leading space,
    /// as Whisper's reference implementation and WhisperKit's own CLI pass it.
    ///
    /// A prompt is read as earlier transcript, where every word carries its
    /// leading space. Without one, the first term tokenises as the start of a
    /// text (`f|etch…`) instead of the word heard mid-sentence (` fetch…`),
    /// and the bias lands with the wrong capital.
    public static func decoderText(_ prompt: String) -> String {
        " " + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cuts at a word boundary rather than mid-word, so the prompt never ends on
    /// a fragment the decoder would try to complete.
    static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let clipped = String(text.prefix(limit))
        guard let lastSpace = clipped.lastIndex(where: { $0 == " " || $0 == "," }) else {
            return clipped
        }
        return String(clipped[..<lastSpace])
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    /// The last `limit` characters, starting at a word boundary.
    static func tail(of text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }

        let clipped = String(collapsed.suffix(limit))
        guard let firstSpace = clipped.firstIndex(of: " ") else { return clipped }
        return String(clipped[clipped.index(after: firstSpace)...])
    }
}
