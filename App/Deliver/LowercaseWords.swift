import AppKit

/// Whether a word is ordinary in lower case — the check `InsertionRules`
/// needs before lowering a capital mid-sentence.
///
/// The system spell checker does most of it: it rejects "january", "monday",
/// "sarah" and "london", so their capitals stay. It accepts some words English
/// still capitalises, though — measured: "english", "polish", "may", "march"
/// — so month, weekday and language names are refused outright.
///
/// Every doubt is a no. A capital left mid-sentence is how dictation pasted
/// before the rules existed; a name turned lower case is damage.
@MainActor
enum LowercaseWords {

    private static var capitalisedNames: [String: Set<String>] = [:]

    /// `word` is already lower case. `language` is a dictation language code.
    static func contains(_ word: String, language: String) -> Bool {
        let checker = NSSpellChecker.shared
        // Asked about a language it has no dictionary for, the checker finds
        // no misspelling — which would read as "every word is fine".
        guard checker.availableLanguages.contains(language) else { return false }
        guard !names(in: language).contains(word) else { return false }
        let misspelled = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location == NSNotFound
    }

    /// Month, weekday and language names in `language`, lower-cased. Built
    /// once per language.
    private static func names(in language: String) -> Set<String> {
        if let cached = capitalisedNames[language] { return cached }
        let locale = Locale(identifier: language)
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let languages = Locale.LanguageCode.isoLanguageCodes.compactMap {
            locale.localizedString(forLanguageCode: $0.identifier)
        }
        let names = Set(
            (calendar.monthSymbols + calendar.weekdaySymbols + languages)
                .map { $0.lowercased(with: locale) })
        capitalisedNames[language] = names
        return names
    }
}
