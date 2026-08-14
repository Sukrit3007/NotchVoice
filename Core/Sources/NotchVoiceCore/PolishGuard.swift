import Foundation

/// The checks a cleanup pass has to survive before its output reaches the user.
///
/// A rewrite is pasted straight into whatever they were typing, so the failure
/// that matters is not "the cleanup was mediocre" — it is words appearing in
/// their document that were never said. Both checks are cheap and are meant to
/// catch disasters, not disagreements.
public enum PolishGuard {

    /// Strips the reasoning block a thinking model emits ahead of its answer.
    ///
    /// The offered model is an instruction-tuned variant with no thinking mode,
    /// so this should never fire. It is here because when it does, the symptom
    /// is a paragraph of the model's private deliberation pasted into the user's
    /// document, and that is worth five lines to prevent.
    public static func withoutReasoning(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            guard let close = result.range(
                of: "</think>", range: open.upperBound ..< result.endIndex)
            else {
                // Unclosed: the model hit its token cap mid-thought. Everything
                // from here on is deliberation and there is no answer to
                // salvage, so what is left fails `isPlausible` and the raw
                // transcript is delivered instead.
                result = String(result[result.startIndex ..< open.lowerBound])
                break
            }
            result.removeSubrange(open.lowerBound ..< close.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rewrites shorter than this fraction of the original are rejected.
    ///
    /// Tuned against real disfluent speech rather than picked round: "um so
    /// like, you know, I was, I was thinking that, uh, maybe we could" is 60%
    /// filler, and a correct cleanup of it legitimately lands near 0.4. A
    /// tighter floor throws away the cleanups that did the most work. What it
    /// still catches is truncation, which loses far more than half.
    private static let minimumRatio = 0.35

    /// And longer than this. A cleanup adds punctuation, paragraph breaks and
    /// list markers; doubling the text means the model answered it instead of
    /// tidying it.
    private static let maximumRatio = 2.0

    /// Whether a rewrite is close enough to the original to still be a rewrite.
    public static func isPlausible(_ polished: String, from original: String) -> Bool {
        guard !polished.isEmpty else { return false }
        let ratio = Double(polished.count) / Double(max(original.count, 1))
        return ratio > minimumRatio && ratio < maximumRatio
    }

    /// Shortest run of instruction text that counts as an echo rather than a
    /// coincidence. A whole sentence; nobody dictates one of these by accident.
    private static let minimumEchoLength = 30

    /// Whether the model repeated its own instructions instead of doing the job.
    ///
    /// Found by running the real path, not theorised: handed the cleanup prompt,
    /// a small model replied with the last paragraph of it, word for word. The
    /// length check waved it through — the echo happened to be about as long as
    /// the transcript — so without this it would have been pasted into whatever
    /// the user was typing.
    ///
    /// Matches whole sentences of the prompt rather than keywords, so a
    /// transcript that happens to use the same words is not caught by it.
    public static func echoes(_ instructions: String, in polished: String) -> Bool {
        instructions
            .split(whereSeparator: { $0 == "." || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= minimumEchoLength }
            .contains { polished.contains($0) }
    }
}
