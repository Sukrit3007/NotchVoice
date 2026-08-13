import Foundation

/// The language the decoder is told to expect.
///
/// `large-v3-turbo` is multilingual and the app was throwing that away with a
/// hardcoded `"en"`. Names come from `Locale` rather than a hand-written table,
/// so they arrive already localised and correctly capitalised for the user's own
/// system language.
enum DictationLanguage: Hashable, Identifiable, Sendable {
    /// Let the model work it out from the audio.
    case automatic
    case fixed(String)

    var id: String { code ?? "auto" }

    /// Nil for automatic, which is what `DecodingOptions.language` wants
    /// alongside `detectLanguage: true`.
    var code: String? {
        switch self {
        case .automatic: nil
        case let .fixed(code): code
        }
    }

    var title: String {
        switch self {
        case .automatic: "Detect automatically"
        case let .fixed(code):
            Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized
                ?? code.uppercased()
        }
    }

    /// A curated list, not all ninety-nine Whisper knows.
    ///
    /// A picker with every language in it is worse than one with the common
    /// ones: the whole point of choosing is to narrow what the decoder expects,
    /// and a list nobody can scan gets left on whatever it defaulted to.
    /// Automatic covers everything not here.
    static let offered: [DictationLanguage] = [
        .automatic,
        .fixed("en"), .fixed("hi"), .fixed("es"), .fixed("fr"), .fixed("de"),
        .fixed("it"), .fixed("pt"), .fixed("nl"), .fixed("ru"), .fixed("ja"),
        .fixed("ko"), .fixed("zh"), .fixed("ar"), .fixed("tr"), .fixed("pl"),
    ]
}

/// Which language dictation assumes.
///
/// Defaults to English rather than automatic. Detection costs a pass over the
/// audio before decoding starts, and it can land on the wrong language for a
/// short take with a proper noun in it — a bad trade for the majority who only
/// ever dictate in one.
enum LanguagePreference {
    private static let key = "dictationLanguage"

    static var current: DictationLanguage {
        get {
            guard let stored = UserDefaults.standard.string(forKey: key) else {
                return .fixed("en")
            }
            return stored == "auto" ? .automatic : .fixed(stored)
        }
        set { UserDefaults.standard.set(newValue.code ?? "auto", forKey: key) }
    }
}
