import Foundation

/// Rewrites phrases in a transcript — dictionary corrections and snippet
/// expansions, which are the same operation with different intent.
///
/// Scanned by hand rather than with `Regex` or `replacingOccurrences`, for two
/// reasons that are both about the input being **user-supplied**:
///
/// - A phrase can contain regex metacharacters. `(` or `?` in a custom word
///   would either throw or silently match something else entirely.
/// - `replacingOccurrences` has no concept of a word boundary, so a rule for
///   "cat" rewrites the middle of "category".
///
/// Rules are applied longest-match-first and never overlap: one pass, left to
/// right, each character consumed once. A replacement is never rescanned, so a
/// rule cannot feed itself.
public enum TranscriptRewriter {

    public struct Rule: Sendable, Equatable {
        /// What the transcript says.
        public let match: String
        /// What it should say instead.
        public let replacement: String

        public init(match: String, replacement: String) {
            self.match = match
            self.replacement = replacement
        }
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        /// Which rules fired, in the order they first did. Drives the
        /// "times applied" counter, and answers "is this rule earning its
        /// keep?" for a user pruning their list.
        public let applied: [String]

        public var didChange: Bool { !applied.isEmpty }
    }

    public static func apply(_ rules: [Rule], to text: String) -> Result {
        // Empty matches would match everywhere and never advance the cursor.
        let usable = rules.filter { !$0.match.isEmpty }
        guard !usable.isEmpty, !text.isEmpty else {
            return Result(text: text, applied: [])
        }

        // Longest first, so "cuber netties" wins over a separate rule for
        // "netties" at the same position rather than losing to whichever
        // happened to be added first.
        let ordered = usable.sorted { $0.match.count > $1.match.count }

        let characters = Array(text)
        var output = ""
        var applied: [String] = []
        var index = 0

        while index < characters.count {
            var matched = false

            for rule in ordered {
                let candidate = Array(rule.match)
                guard index + candidate.count <= characters.count else { continue }
                guard hasBoundaries(in: characters, at: index, length: candidate.count) else {
                    continue
                }
                guard equalsIgnoringCase(characters, at: index, candidate) else { continue }

                output += rule.replacement
                if !applied.contains(rule.match) { applied.append(rule.match) }
                index += candidate.count
                matched = true
                break
            }

            if !matched {
                output.append(characters[index])
                index += 1
            }
        }

        return Result(text: output, applied: applied)
    }

    /// True when a match at this position is a whole word on both sides.
    ///
    /// "Word" means alphanumeric here: a match may not start or end flush
    /// against a letter or a digit. Punctuation and whitespace are fine, which
    /// is what lets "cuber netties." be rewritten while "cuber nettiesque" is
    /// left alone.
    private static func hasBoundaries(
        in characters: [Character], at index: Int, length: Int
    ) -> Bool {
        if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber {
            return false
        }
        let after = index + length
        if after < characters.count,
           characters[after].isLetter || characters[after].isNumber {
            return false
        }
        return true
    }

    /// Case-insensitive comparison at a position, without allocating a substring
    /// for every candidate at every index.
    private static func equalsIgnoringCase(
        _ characters: [Character], at index: Int, _ candidate: [Character]
    ) -> Bool {
        for offset in 0..<candidate.count {
            let a = characters[index + offset]
            let b = candidate[offset]
            guard a == b || String(a).lowercased() == String(b).lowercased() else {
                return false
            }
        }
        return true
    }
}
