import Foundation

/// The speech models the app offers, and what each costs.
///
/// Offered because the default is a 632MB model held permanently in memory,
/// which is a lot to ask of a 8GB Mac that is also running an IDE. Sizes and
/// names match the CoreML variants WhisperKit publishes; the wording is about
/// what the user gives up, since "large-v3-turbo" tells them nothing.
enum SpeechModel: String, CaseIterable, Identifiable, Sendable {
    case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case small = "openai_whisper-small"
    case base = "openai_whisper-base"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turbo: "Accurate"
        case .small: "Balanced"
        case .base: "Light"
        }
    }

    /// Approximate on-disk download, which is also roughly what stays resident.
    var approximateSize: String {
        switch self {
        case .turbo: "630 MB"
        case .small: "250 MB"
        case .base: "80 MB"
        }
    }

    var detail: String {
        switch self {
        case .turbo:
            "The best transcription this app can do, and the default. "
            + "Stays in memory so every dictation starts instantly."
        case .small:
            "Noticeably lighter, and still good on clear speech. "
            + "Worth trying if memory is tight."
        case .base:
            "Smallest and quickest to load. Expect more mistakes on names, "
            + "accents and anything said quickly."
        }
    }
}

/// Which speech model to load.
///
/// Changing it is not free: the new one has to be downloaded if it has never
/// been used, then loaded, and dictation cannot work in between. The Settings
/// pane says so rather than appearing to switch instantly.
enum ModelPreference {
    private static let key = "speechModel"

    static var current: SpeechModel {
        get {
            guard let stored = UserDefaults.standard.string(forKey: key),
                  let model = SpeechModel(rawValue: stored)
            else { return .turbo }
            return model
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}
