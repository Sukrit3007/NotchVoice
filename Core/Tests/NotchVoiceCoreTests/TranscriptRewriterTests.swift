import Testing
@testable import NotchVoiceCore

private func rewrite(_ text: String, _ rules: [(String, String)]) -> TranscriptRewriter.Result {
    TranscriptRewriter.apply(
        rules.map { TranscriptRewriter.Rule(match: $0.0, replacement: $0.1) },
        to: text
    )
}

@Suite("TranscriptRewriter")
struct TranscriptRewriterTests {

    // MARK: - The point of it

    @Test("a misheard phrase is corrected")
    func rewritesAPhrase() {
        let result = rewrite("we deployed it to cuber netties", [("cuber netties", "Kubernetes")])
        #expect(result.text == "we deployed it to Kubernetes")
        #expect(result.applied == ["cuber netties"])
    }

    @Test("matching ignores case but the replacement keeps its own")
    func caseInsensitiveMatchExactReplacement() {
        // The user typed "Kubernetes" with a capital; that is the spelling they
        // want, wherever in the sentence it lands.
        let result = rewrite("Cuber Netties is fine", [("cuber netties", "Kubernetes")])
        #expect(result.text == "Kubernetes is fine")
    }

    // MARK: - Word boundaries

    @Test("a rule does not fire inside a longer word")
    func respectsWordBoundaries() {
        // The whole reason this is not `replacingOccurrences`.
        let result = rewrite("the category is broad", [("cat", "dog")])
        #expect(result.text == "the category is broad")
        #expect(!result.didChange)
    }

    @Test("punctuation still counts as a boundary")
    func punctuationIsABoundary() {
        let result = rewrite("deploy to cuber netties.", [("cuber netties", "Kubernetes")])
        #expect(result.text == "deploy to Kubernetes.")
    }

    @Test("a match at the very start and very end still fires")
    func matchesAtEdges() {
        #expect(rewrite("cat", [("cat", "dog")]).text == "dog")
        #expect(rewrite("a cat", [("cat", "dog")]).text == "a dog")
        #expect(rewrite("cat a", [("cat", "dog")]).text == "dog a")
    }

    // MARK: - Ordering and overlap

    @Test("when one rule is a prefix of another, the longer one wins")
    func longestMatchWins() {
        // The rules must **both match at the same index** or ordering is never
        // exercised. An earlier version of this test used "netties" against
        // "cuber netties", where the short rule cannot match at position 0 at
        // all — it passed with the sort reversed, which is to say it tested
        // nothing. A shared prefix is what makes the comparison real.
        let result = rewrite(
            "pull request review",
            [("pull", "PULL"), ("pull request", "PR")]
        )
        #expect(result.text == "PR review")
        #expect(result.applied == ["pull request"])
    }

    @Test("the longer rule wins regardless of the order it was added in")
    func orderingIsNotInsertionOrder() {
        let longFirst = rewrite("pull request", [("pull request", "PR"), ("pull", "PULL")])
        let shortFirst = rewrite("pull request", [("pull", "PULL"), ("pull request", "PR")])
        #expect(longFirst.text == "PR")
        #expect(shortFirst.text == "PR")
    }

    @Test("a replacement is not rescanned")
    func replacementsDoNotCascade() {
        // Otherwise a rule that produces its own match loops or double-applies.
        let result = rewrite("cat", [("cat", "cat cat")])
        #expect(result.text == "cat cat")
    }

    @Test("several different rules can fire in one pass")
    func multipleRulesApply() {
        let result = rewrite(
            "cuber netties and whisper kit",
            [("cuber netties", "Kubernetes"), ("whisper kit", "WhisperKit")]
        )
        #expect(result.text == "Kubernetes and WhisperKit")
        #expect(result.applied == ["cuber netties", "whisper kit"])
    }

    @Test("the same rule firing twice is only reported once")
    func repeatsAreCountedOnce() {
        let result = rewrite("cat and cat", [("cat", "dog")])
        #expect(result.text == "dog and dog")
        #expect(result.applied == ["cat"])
    }

    // MARK: - Hostile input

    @Test("regex metacharacters in a phrase are literal")
    func metacharactersAreLiteral() {
        // A user's custom word can be anything they typed. With a regex
        // implementation these either throw or match the wrong thing.
        #expect(rewrite("what (a) thing", [("(a)", "the")]).text == "what the thing")
        #expect(rewrite("cost is 5.00", [("5.00", "five")]).text == "cost is five")
        #expect(rewrite("a [b] c", [("[b]", "B")]).text == "a B c")
    }

    @Test("an empty rule cannot match and cannot hang")
    func emptyRulesAreIgnored() {
        let result = rewrite("hello", [("", "x")])
        #expect(result.text == "hello")
        #expect(!result.didChange)
    }

    @Test("nothing to do leaves the text untouched")
    func noRulesNoChange() {
        #expect(rewrite("hello", []).text == "hello")
        #expect(rewrite("", [("a", "b")]).text == "")
    }

    @Test("non-Latin text is matched by whole word too")
    func unicodeBoundaries() {
        // isLetter is Unicode-aware, so this must behave like the Latin case.
        let result = rewrite("привет мир", [("мир", "world")])
        #expect(result.text == "привет world")
    }
}

@Suite("BiasPrompt")
struct BiasPromptTests {

    @Test("no terms and no context produces no prompt")
    func emptyIsNil() {
        #expect(BiasPrompt.build(terms: []) == nil)
        #expect(BiasPrompt.build(terms: [], context: "") == nil)
        #expect(BiasPrompt.build(terms: ["  "]) == nil)
    }

    @Test("terms are listed for the decoder")
    func listsTerms() {
        #expect(BiasPrompt.build(terms: ["Kubernetes", "WhisperKit"]) == "Kubernetes, WhisperKit")
    }

    @Test("context is appended after the terms")
    func appendsContext() {
        let prompt = BiasPrompt.build(terms: ["Sukrit"], context: "Reviewing the PR")
        #expect(prompt == "Sukrit. Reviewing the PR")
    }

    @Test("the prompt stays inside its budget")
    func respectsBudget() {
        let manyTerms = (0..<400).map { "term\($0)" }
        let prompt = BiasPrompt.build(terms: manyTerms, context: String(repeating: "x ", count: 500))
        #expect(prompt!.count <= BiasPrompt.characterBudget)
    }

    @Test("truncation never leaves a half word")
    func truncatesAtWords() {
        let cut = BiasPrompt.truncated("alpha beta gamma", to: 12)
        #expect(cut == "alpha beta")
        #expect(!cut.hasSuffix("gam"))
    }

    @Test("context is taken from the end, nearest the cursor")
    func contextTakesTheTail() {
        // What the next sentence continues from is the text just before the
        // cursor, not the top of the document.
        let tail = BiasPrompt.tail(of: "the beginning is long and old. the recent part", limit: 20)
        #expect(tail.hasSuffix("recent part"))
        #expect(!tail.contains("beginning"))
    }

    @Test("newlines in context are flattened")
    func contextIsSingleLine() {
        let tail = BiasPrompt.tail(of: "one\ntwo\nthree", limit: 100)
        #expect(!tail.contains("\n"))
        #expect(tail == "one two three")
    }
}
