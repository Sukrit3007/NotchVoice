import Testing
@testable import NotchVoice

/// Against the real system spell checker, which is what decides whether a
/// capital mid-sentence may be lowered. No names a user might have taught it.
@MainActor
@Suite("LowercaseWords")
struct LowercaseWordsTests {

    @Test("ordinary words are words in lower case",
          arguments: ["that's", "big", "apples", "account", "however"])
    func ordinaryWords(_ word: String) {
        #expect(LowercaseWords.contains(word, language: "en"))
    }

    @Test("months, weekdays and places are not",
          arguments: ["january", "monday", "london", "tuesday"])
    func properNouns(_ word: String) {
        #expect(!LowercaseWords.contains(word, language: "en"))
    }

    @Test("names the spell checker would let through are refused anyway",
          arguments: ["english", "polish", "may", "march", "august", "dutch"])
    func capitalisedNamesThatSpellCheck(_ word: String) {
        #expect(!LowercaseWords.contains(word, language: "en"))
    }

    @Test("a language with no dictionary answers no, not yes")
    func unknownLanguageIsNo() {
        // Asked about one, the checker reports no misspelling at all.
        #expect(!LowercaseWords.contains("house", language: "xx"))
    }
}
