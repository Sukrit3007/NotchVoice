import Testing
@testable import NotchVoiceCore

/// One row of the golden table: the text either side of the caret, what the
/// dictation came out as, and the line as it should read once pasted.
struct Golden: CustomTestStringConvertible, Sendable {
    let before: String
    let text: String
    let after: String
    let expected: String
    var terms: [String] = []
    var language: String?

    init(
        _ before: String, _ text: String, _ after: String, _ expected: String,
        terms: [String] = [], language: String? = "en"
    ) {
        self.before = before
        self.text = text
        self.after = after
        self.expected = expected
        self.terms = terms
        self.language = language
    }

    /// Stands in for the App's spell check: the lower-case words these rows
    /// lower. Anything missing — "january", "sarah" — is not a word, as the
    /// real check says (see the App's `LowercaseWords`).
    static let words: Set<String> = [
        "that's", "plums", "yes", "a", "apples", "world", "big", "in", "thanks",
        "bar", "below", "hi", "account", "auto", "general",
    ]

    var testDescription: String { "\(before.debugDescription) ‸ \(after.debugDescription) → \(expected.debugDescription)" }

    var result: String {
        let fit = InsertionRules.fit(
            text, between: .init(before: before, after: after), keepingCaseOf: terms,
            language: language, isWord: { Self.words.contains($0) })
        return before + fit.text + after
    }
}

@Suite("InsertionRules")
struct InsertionRulesTests {

    // MARK: - Golden table

    @Test("an empty field takes the dictation as written", arguments: [
        Golden("", "Hello world.", "", "Hello world."),
        Golden("", "  Hello world.  ", "", "Hello world."),
    ])
    func emptyField(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("mid-sentence: spaced, lower case, stop kept at the end", arguments: [
        Golden("I think", "That's fine.", "", "I think that's fine."),
        Golden("I think ", "That's fine.", "", "I think that's fine."),
        Golden("Apples, pears,", "Plums.", "", "Apples, pears, plums."),
        Golden("I said ", "Yes. Then I left.", "", "I said yes. Then I left."),
        Golden("this is ", "A test.", "", "this is a test."),
        Golden("I have ", "3 apples.", "", "I have 3 apples."),
        Golden("fruit, e.g. ", "Apples.", "", "fruit, e.g. apples."),
        Golden("Hello\u{00A0}", "World.", "", "Hello\u{00A0}world."),
        Golden("Hello ", " world.", "", "Hello world."),
    ])
    func midSentence(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("a sentence start keeps the capital", arguments: [
        Golden("First. ", "Second one.", "", "First. Second one."),
        Golden("First.", "Second one.", "", "First. Second one."),
        Golden("Really? ", "Yes.", "", "Really? Yes."),
        Golden("Line one\n", "Next line.", "", "Line one\nNext line."),
        Golden("Line one\n  ", "Indented.", "", "Line one\n  Indented."),
        Golden("Note: ", "The build is green.", "", "Note: The build is green."),
        Golden("- ", "Buy milk.", "", "- Buy milk."),
        Golden("\t", "Item.", "", "\tItem."),
        Golden("Wait... ", "No.", "", "Wait... No."),
    ])
    func sentenceStart(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("a capital that is not just a sentence start is kept", arguments: [
        Golden("and then ", "I left.", "", "and then I left."),
        Golden("so ", "I'm here.", "", "so I'm here."),
        Golden("so ", "I’ll go.", "", "so I’ll go."),
        Golden("we use the ", "API daily.", "", "we use the API daily."),
        Golden("we ate at ", "McDonald's today.", "", "we ate at McDonald's today."),
        Golden("I spoke with ", "Sukrit today.", "", "I spoke with Sukrit today.", terms: ["Sukrit"]),
        Golden("we moved to ", "New York.", "", "we moved to New York.", terms: ["New York"]),
        Golden("I met Priya and ", "Priya agreed.", "", "I met Priya and Priya agreed."),
        Golden("then ", "Priya's turn.", " and Priya's call", "then Priya's turn and Priya's call"),
    ])
    func keptCapitals(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("unsure keeps the capital", arguments: [
        // Not ordinary words in lower case: months, days, languages, names.
        Golden("Due in ", "January.", "", "Due in January."),
        Golden("Let's meet on ", "Monday at 3.", "", "Let's meet on Monday at 3."),
        Golden("She speaks ", "English.", "", "She speaks English."),
        Golden("I spoke to ", "Sarah", " yesterday", "I spoke to Sarah yesterday"),
        Golden("Priya called. I said ", "Priya agreed.", "", "Priya called. I said Priya agreed."),
        Golden("and then ", "I left.", "", "and then I left."),
        // German capitalises every noun, so nothing is lowered there.
        Golden("Ich habe gestern ein ", "Auto gekauft.", "", "Ich habe gestern ein Auto gekauft.", language: "de"),
        // Turkish lowers I to ı; detected languages are unknown.
        Golden("ve ", "In the box.", "", "ve In the box.", language: "tr"),
        Golden("I think ", "That's fine.", "", "I think That's fine.", language: nil),
    ])
    func unsureKeepsCapital(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("before existing text: no stop when the sentence carries on", arguments: [
        Golden("Intro\n", "Hello.", "world is big", "Intro\nHello world is big"),
        Golden("I went to the ", "Big.", "store.", "I went to the big store."),
        Golden("Hello ", "Big.", ", friend", "Hello big, friend"),
        Golden("Hello ", "Big.", "  world", "Hello big  world"),
        Golden("Intro\n", "Buy.", "2 apples", "Intro\nBuy 2 apples"),
        Golden("Yesterday ", "In the evening.", "I went home.", "Yesterday in the evening I went home."),
        Golden("Intro\n", "Done. ", " rest", "Intro\nDone rest"),
    ])
    func beforeExistingText(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("a whole sentence slotted in before another keeps its stop", arguments: [
        Golden("Intro\n", "Hello.", "The end.", "Intro\nHello. The end."),
        Golden("One. ", "Two.", "Three.", "One. Two. Three."),
        Golden("Hello. ", "Thanks.", "I agree.", "Hello. Thanks. I agree."),
    ])
    func sentenceBetweenSentences(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("nothing more on the caret's line keeps the stop", arguments: [
        Golden("Hello ", "World.", "\nNext line", "Hello world.\nNext line"),
        Golden("Hello ", "World.", "   ", "Hello world.   "),
    ])
    func stopKeptAtLineEnd(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("a stop that belongs to the text is kept", arguments: [
        Golden("", "Use a tool, e.g.", " more", "Use a tool, e.g. more"),
        Golden("", "Apples, pears, etc.", " are fine", "Apples, pears, etc. are fine"),
        Golden("", "Made in the U.S.", " today", "Made in the U.S. today"),
        Golden("", "Wait...", " and then", "Wait... and then"),
        Golden("", "Really?", " she said", "Really? she said"),
    ])
    func stopsThatStay(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("a selection is replaced cleanly", arguments: [
        // "Hello [cruel] world" with "cruel" selected.
        Golden("Hello ", "Big.", " world", "Hello big world"),
        // "[Hello] world" with "Hello" selected.
        Golden("", "Goodbye.", " world", "Goodbye world"),
        // The whole field selected.
        Golden("", "Hello.", "", "Hello."),
    ])
    func selectionReplaced(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("URLs and email addresses nearby", arguments: [
        Golden("see https://example.com/", "Docs.", "", "see https://example.com/Docs."),
        Golden("write to me@example.com", "Thanks.", "", "write to me@example.com thanks."),
        Golden("ping @", "Priya.", "", "ping @Priya."),
        Golden("Visit example.com. ", "It's down.", "", "Visit example.com. It's down."),
        Golden("", "Visit example.com.", " for details", "Visit example.com for details"),
        Golden("", "Mail sukrit@example.com.", " today", "Mail sukrit@example.com today"),
        Golden("Version ", "2.0.", " ships", "Version 2.0 ships"),
    ])
    func urlsAndEmails(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("code-ish contexts", arguments: [
        Golden("print(", "Hello world.", ")", "print(Hello world)"),
        Golden("let name = ", "Value.", "", "let name = Value."),
        Golden("items[", "Index.", "]", "items[Index]"),
        Golden("$ ", "Git status.", "   ", "$ Git status.   "),
        Golden("foo", "Bar.", "(x)", "foo bar (x)"),
    ])
    func codeContexts(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("quotes and brackets", arguments: [
        Golden("He said \"", "Hello.", "\"", "He said \"Hello\""),
        Golden("the \"beta\"", "Ships today.", "", "the \"beta\" Ships today."),
        Golden("He said “", "Hello.", "”", "He said “Hello”"),
        Golden("(see ", "Below.", ")", "(see below)"),
        Golden("I said", "Hi.", " \"there\"", "I said hi \"there\""),
    ])
    func quotesAndBrackets(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("scripts without spaces between words", arguments: [
        Golden("你好", "世界。", "", "你好世界。"),
        Golden("今日は", "いい天気。", "です", "今日はいい天気。です"),
    ])
    func cjk(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("other languages are spaced and stopped, but keep their capitals", arguments: [
        Golden("Я думаю", "Это хорошо.", "", "Я думаю Это хорошо.", language: "ru"),
        Golden("Creo que", "Es posible.", " ahora", "Creo que Es posible ahora", language: "es"),
    ])
    func otherLanguages(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("part of a word or identifier joins without spaces", arguments: [
        // "get[User]Name" with "User" selected.
        Golden("get", "Account.", "Name", "getAccountName"),
        // A bare caret inside "getUser|Name".
        Golden("getUser", "Account.", "Name", "getUserAccountName"),
        Golden("snake_", "Case.", "_name", "snake_Case_name"),
    ])
    func insideAWord(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("no space after a prefix character", arguments: [
        Golden("join #", "General.", "", "join #General."),
        Golden("costs $", "5.", "", "costs $5."),
        Golden("ping @", "Priya.", "", "ping @Priya."),
        Golden("open ~/", "Notes.", "", "open ~/Notes."),
    ])
    func prefixCharacters(_ row: Golden) { #expect(row.result == row.expected) }

    @Test("newlines in the dictation are content, not spacing", arguments: [
        Golden("Hi", "\nBest regards", "", "Hi\nBest regards"),
        Golden("", "Line one\n", "more", "Line one\nmore"),
    ])
    func newlinesAreContent(_ row: Golden) { #expect(row.result == row.expected) }

    // MARK: - What it reports

    @Test("each change is reported, and nothing else")
    func reportsAdjustments() {
        let fit = InsertionRules.fit(
            "Big.", between: .init(before: "Hello,", after: "world"),
            language: "en", isWord: { _ in true })
        #expect(fit.text == " big ")
        #expect(fit.adjustments == [.lowercased, .droppedPeriod, .leadingSpace, .trailingSpace])

        let untouched = InsertionRules.fit("Hello.", between: .init(before: "", after: ""))
        #expect(untouched.text == "Hello.")
        #expect(untouched.adjustments.isEmpty)
    }

    @Test("without a language and a word check, nothing is lowered")
    func lowersNothingByDefault() {
        let fit = InsertionRules.fit("That's fine.", between: .init(before: "I think ", after: ""))
        #expect(fit.text == "That's fine.")
        #expect(InsertionRules.fit(
            "That's fine.", between: .init(before: "I think ", after: ""), language: "en-GB",
            isWord: { _ in true }).text == "that's fine.")
    }

    @Test("an all-space dictation comes back as it was")
    func blankIsLeftAlone() {
        let fit = InsertionRules.fit("   ", between: .init(before: "a", after: "b"))
        #expect(fit.text == "   ")
        #expect(fit.adjustments.isEmpty)
    }

    // MARK: - Surroundings from a field

    typealias Surroundings = InsertionRules.Surroundings

    @Test("a caret splits the value")
    func caretSplits() {
        let s = Surroundings(value: "Hello world", selectionLocation: 6, selectionLength: 0)
        #expect(s == Surroundings(before: "Hello ", after: "world"))
    }

    @Test("a selection is left out of both sides")
    func selectionIsExcluded() {
        let s = Surroundings(value: "Hello cruel world", selectionLocation: 6, selectionLength: 5)
        #expect(s == Surroundings(before: "Hello ", after: " world"))
    }

    @Test("each side is bounded")
    func windowsAreBounded() {
        let value = String(repeating: "a", count: 1000) + String(repeating: "b", count: 1000)
        let s = Surroundings(value: value, selectionLocation: 1000, selectionLength: 0)
        #expect(s?.before == String(repeating: "a", count: Surroundings.window))
        #expect(s?.after == String(repeating: "b", count: Surroundings.window))
    }

    @Test("ranges are in UTF-16 units, as Accessibility reports them")
    func utf16Offsets() {
        // 👋 is two UTF-16 units, so the caret after "👋 " is at 3, not 2.
        let s = Surroundings(value: "👋 hi", selectionLocation: 3, selectionLength: 0)
        #expect(s == Surroundings(before: "👋 ", after: "hi"))
    }

    @Test("a range the value cannot hold means the field cannot be trusted")
    func outOfRangeIsNil() {
        #expect(Surroundings(value: "short", selectionLocation: 9, selectionLength: 0) == nil)
        #expect(Surroundings(value: "short", selectionLocation: 3, selectionLength: 5) == nil)
        #expect(Surroundings(value: "short", selectionLocation: -1, selectionLength: 0) == nil)
    }

    @Test("a caret at the very start keeps nothing after it, which may be a placeholder")
    func caretAtStartIgnoresAfter() {
        // An empty composer can expose "Ask anything" as its value.
        let s = Surroundings(value: "Ask anything", selectionLocation: 0, selectionLength: 0)
        #expect(s == Surroundings(before: "", after: ""))
        let fit = InsertionRules.fit("Hello world.", between: s!)
        #expect(fit.text == "Hello world.")
        // A selection at the start is real text, so what follows it counts.
        #expect(Surroundings(value: "Hello world", selectionLocation: 0, selectionLength: 5)
                == Surroundings(before: "", after: " world"))
        #expect(Surroundings(value: "", selectionLocation: 0, selectionLength: 0)
                == Surroundings(before: "", after: ""))
    }

    @Test("a terminal's NUL padding reads as spaces, so nothing follows the caret")
    func nulPaddingIsSpace() {
        let s = Surroundings(value: "$ \0\0\0", selectionLocation: 2, selectionLength: 0)
        #expect(s == Surroundings(before: "$ ", after: "   "))
        let fit = InsertionRules.fit("Git status.", between: s!)
        #expect(fit.text == "Git status.")
    }
}
