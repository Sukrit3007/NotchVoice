/// Fits a finished dictation to the text already around the caret.
///
/// Cleanup writes every dictation as a sentence of its own — capital first,
/// full stop last — because it never sees where the words are going. Pasted
/// after "I think", that reads "I thinkThat's fine." This pass knows the text
/// either side of the caret and makes the fixes a person would at the two
/// joins: a space where one is missing, lower case when the dictation carries
/// on a sentence, no full stop when the sentence carries on past the caret.
///
/// Done in code rather than by the cleanup model: the rules are few, they have
/// to be right every time, and the model would have to be handed the user's
/// surrounding text to do them.
///
/// Only the edges of the dictation change. Nothing inside it is touched, and
/// the text around the caret is read, never rewritten.
///
/// Pure: the host reads the field over Accessibility.
public enum InsertionRules {

    /// The text either side of the caret — or of the selection the paste will
    /// replace — in bounded windows, never the whole field.
    public struct Surroundings: Equatable, Sendable {
        public let before: String
        public let after: String

        /// How much of each side is kept, in UTF-16 units. The rules look at a
        /// few characters at each join; the rest is there to spot names the
        /// field already capitalises.
        public static let window = 200

        public init(before: String, after: String) {
            self.before = before
            self.after = after
        }

        /// Cut from a field's value around a range, in the UTF-16 units
        /// Accessibility reports ranges in.
        ///
        /// Nil when the range does not fit inside the value: the app's caret
        /// and its text disagree, and nothing decided from them can be trusted.
        ///
        /// `placeholder` is the field's own: some fields report it as their
        /// value while empty, and its text is not something to join onto.
        public init?(
            value: String, selectionLocation: Int, selectionLength: Int, placeholder: String? = nil
        ) {
            if let placeholder, !placeholder.isEmpty, value == placeholder {
                self.init(before: "", after: "")
                return
            }
            let units = value.utf16
            let end = selectionLocation + selectionLength
            guard selectionLocation >= 0, selectionLength >= 0, end <= units.count else {
                return nil
            }
            let index = { units.index(units.startIndex, offsetBy: $0) }
            let lower = max(0, selectionLocation - Self.window)
            let upper = min(units.count, end + Self.window)
            self.init(
                before: Self.readable(units[index(lower) ..< index(selectionLocation)]),
                after: Self.readable(units[index(end) ..< index(upper)]))
        }

        /// Terminals pad their text with NULs, which are spaces on screen.
        private static func readable(_ units: Substring.UTF16View) -> String {
            String(String(decoding: units, as: UTF16.self).map { $0 == "\0" ? " " : $0 })
        }
    }

    /// What was changed, for the log — which never sees the text itself.
    public enum Adjustment: String, Sendable {
        case leadingSpace
        case lowercased
        case droppedPeriod
        case trailingSpace
    }

    public struct Fit: Equatable, Sendable {
        public let text: String
        public let adjustments: [Adjustment]
    }

    /// The dictation as it should land between `surroundings`.
    ///
    /// `terms` are spellings whose capitals are deliberate — custom words,
    /// snippet expansions. A dictation that starts with one keeps its capital
    /// even mid-sentence.
    public static func fit(
        _ text: String, between surroundings: Surroundings, keepingCaseOf terms: [String] = []
    ) -> Fit {
        let before = surroundings.before
        let after = surroundings.after

        // Spaces at the edges are decided by the joins below, so any the text
        // arrived with go. Newlines stay: they are content.
        var body = String(text.drop(while: isInlineSpace))
        while let last = body.last, isInlineSpace(last) { body.removeLast() }
        guard !body.isEmpty else { return Fit(text: text, adjustments: []) }

        var adjustments: [Adjustment] = []
        let continuing = continuesSentence(before)

        if continuing, let lowered = lowercasingFirstWord(of: body, near: before + " " + after, terms: terms) {
            body = lowered
            adjustments.append(.lowercased)
        }

        if dropsPeriod(from: body, continuing: continuing, after: after) {
            body.removeLast()
            adjustments.append(.droppedPeriod)
        }

        if needsSpace(before.dropLast().last, before.last, body.first, body.dropFirst().first) {
            body = " " + body
            adjustments.append(.leadingSpace)
        }

        if needsSpace(body.dropLast().last, body.last, after.first, after.dropFirst().first) {
            body += " "
            adjustments.append(.trailingSpace)
        }

        return Fit(text: body, adjustments: adjustments)
    }

    // MARK: - Casing

    /// Whether the caret sits inside a sentence: the last thing on its line is
    /// a word or a comma. A line's start, a full stop, a colon, a bracket — any
    /// of those could be followed by a capital, so the dictation keeps its own.
    static func continuesSentence(_ before: String) -> Bool {
        var line = lastLine(of: before)
        while let last = line.last, isInlineSpace(last) { line.removeLast() }
        guard let last = line.last else { return false }
        if last.isLetter || last.isNumber || last == "," || last == ";" { return true }
        // "for example" and "that is" are never the end of a sentence.
        let word = withoutOpeners(line.split(whereSeparator: \.isWhitespace).last ?? "").lowercased()
        return word == "e.g." || word == "i.e."
    }

    private static func lastLine(of text: String) -> Substring {
        guard let newline = text.lastIndex(where: \.isNewline) else { return Substring(text) }
        return text[text.index(after: newline)...]
    }

    private static func withoutOpeners(_ word: Substring) -> Substring {
        word.drop { "([{“‘«\"'".contains($0) }
    }

    /// The text with its first letter lowered, or nil when that capital is
    /// not just the start of a sentence: "I", an acronym, a mixed-case name,
    /// a term the user spelled, or a word the surrounding text capitalises
    /// mid-sentence — which is as close to "a name" as can be told locally.
    static func lowercasingFirstWord(of text: String, near context: String, terms: [String]) -> String? {
        guard let first = text.first, first.isUppercase else { return nil }
        let word = text.prefix { $0.isLetter || $0.isNumber || "'’-".contains($0) }

        if word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’") { return nil }
        if word.dropFirst().contains(where: \.isUppercase) { return nil }
        if terms.contains(where: { startsWith(text, term: $0) }) { return nil }
        if isCapitalisedMidSentence(leadingLetters(of: text), in: context) { return nil }

        return first.lowercased() + text.dropFirst()
    }

    /// True when `text` begins with `term`, spelled exactly, as a whole word.
    private static func startsWith(_ text: String, term: String) -> Bool {
        let term = term.trimmingSpaces
        guard !term.isEmpty, text.hasPrefix(term) else { return false }
        guard let next = text.dropFirst(term.count).first else { return true }
        return !(next.isLetter || next.isNumber)
    }

    private static func isCapitalisedMidSentence(_ word: Substring, in context: String) -> Bool {
        guard !word.isEmpty else { return false }
        for line in context.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            // From the second token: the first has nothing before it to show
            // it is mid-sentence, and may be cut off by the window anyway.
            for (previous, token) in zip(tokens, tokens.dropFirst()) {
                guard let end = previous.last,
                      end.isLetter || end.isNumber || end == "," || end == ";"
                else { continue }
                if leadingLetters(of: withoutOpeners(token)) == word { return true }
            }
        }
        return false
    }

    private static func leadingLetters<S: StringProtocol>(of text: S) -> Substring {
        Substring(text.prefix { $0.isLetter || $0.isNumber })
    }

    // MARK: - Full stop

    /// Whether the dictation's closing full stop should go: something follows
    /// on the caret's line, and the dictation is not a whole sentence of its
    /// own slotted in before another one.
    static func dropsPeriod(from text: String, continuing: Bool, after: String) -> Bool {
        guard text.last == "." else { return false }
        // An ellipsis is deliberate, and an abbreviation's stop is part of it.
        if text.hasSuffix("..") { return false }
        let lastWord = text.split(whereSeparator: \.isWhitespace).last ?? ""
        if isAbbreviation(lastWord) { return false }

        let line = after.prefix { !$0.isNewline }
        guard let next = line.first(where: { !$0.isWhitespace }) else { return false }
        // "One. | Three." — a capital after a sentence boundary is the next
        // sentence, and the dictation is a sentence between the two.
        if !continuing, next.isUppercase { return false }
        return true
    }

    private static let abbreviations: Set<String> = ["etc.", "vs.", "inc.", "ltd."]

    /// "e.g.", "U.S.", "a.m." — single letters each with a stop — or a short
    /// list of words that are rarely anything but abbreviations.
    private static func isAbbreviation(_ word: Substring) -> Bool {
        let word = withoutOpeners(word).lowercased()
        if abbreviations.contains(word) { return true }
        let characters = Array(word)
        guard characters.count >= 4, characters.count.isMultiple(of: 2) else { return false }
        return stride(from: 0, to: characters.count, by: 2).allSatisfy {
            characters[$0].isLetter && characters[$0 + 1] == "."
        }
    }

    // MARK: - Spacing

    /// Whether a space belongs between `left` and `right`, the two characters
    /// either side of a join. Their outer neighbours tell an opening straight
    /// quote from a closing one.
    static func needsSpace(
        _ outerLeft: Character?, _ left: Character?, _ right: Character?, _ outerRight: Character?
    ) -> Bool {
        guard let left, let right else { return false }
        if left.isWhitespace || right.isWhitespace { return false }
        // Chinese and Japanese are written without spaces between words.
        if isCJK(left) || isCJK(right) { return false }
        // Nothing after an opening bracket or quote, or inside a path, an
        // address or a handle: "foo(", "example.com/", "@".
        if opensGroup(left, after: outerLeft) || left == "/" || left == "@" { return false }
        // Nothing before punctuation or a closing bracket or quote.
        if ".,;:!?".contains(right) || closesGroup(right, before: outerRight) { return false }
        return true
    }

    private static func opensGroup(_ character: Character, after previous: Character?) -> Bool {
        if "([{“‘«".contains(character) { return true }
        guard character == "\"" || character == "'" else { return false }
        guard let previous else { return true }
        return previous.isWhitespace || "([{".contains(previous)
    }

    private static func closesGroup(_ character: Character, before next: Character?) -> Bool {
        if ")]}”’»".contains(character) { return true }
        guard character == "\"" || character == "'" else { return false }
        guard let next else { return true }
        return next.isWhitespace || ".,;:!?)]}".contains(next)
    }

    private static func isInlineSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    private static func isCJK(_ character: Character) -> Bool {
        guard let value = character.unicodeScalars.first?.value else { return false }
        return (0x3000 ... 0x30FF).contains(value)     // CJK punctuation, kana
            || (0x3400 ... 0x4DBF).contains(value)     // ideographs, extension A
            || (0x4E00 ... 0x9FFF).contains(value)     // ideographs
            || (0xF900 ... 0xFAFF).contains(value)     // compatibility ideographs
            || (0xFF00 ... 0xFFEF).contains(value)     // full-width forms
            || (0x20000 ... 0x2FA1F).contains(value)   // ideographs, later extensions
    }
}

private extension String {
    var trimmingSpaces: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
