/// Why a dictation produced nothing usable.
///
/// Two strings per case, because there are two places to say it and they have
/// wildly different budgets. The island's widest wing holds about 84pt of 11pt
/// text — one word — while the panel below the notch has a full line. Carrying
/// both here is what stops the island from being handed a sentence it silently
/// truncates — "Nothing heard" renders as "Nothi…" in a wing.
enum DictationFailure: Equatable {
    case noMicrophone
    /// Audio arrived, but nothing in it was speech.
    case silent
    /// The speech model had not finished loading.
    case modelLoading
    case transcriptionFailed
    /// A second key press arrived before the previous dictation finished.
    case stillProcessing

    /// One word, for the island's trailing wing.
    var short: String {
        switch self {
        case .noMicrophone: "No mic"
        case .silent: "Silent"
        case .modelLoading: "Loading"
        case .transcriptionFailed: "Failed"
        case .stillProcessing: "Busy"
        }
    }

    /// A sentence, for the panel below the notch.
    ///
    /// Each says what happened and what to do about it. "Something went wrong"
    /// is not a message, it is an apology — if there is nothing useful to
    /// suggest, the case should not exist.
    var message: String {
        switch self {
        case .noMicrophone:
            "Couldn't start the microphone. Check it isn't in use by another app."
        case .silent:
            "Didn't hear anything. Check your input device and its volume."
        case .modelLoading:
            "Still loading the speech model. Try again in a moment."
        case .transcriptionFailed:
            "Couldn't transcribe that. The details are in Console."
        case .stillProcessing:
            "Still processing the previous dictation. Try again in a moment."
        }
    }
}
