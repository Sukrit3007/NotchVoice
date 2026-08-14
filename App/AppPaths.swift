import Foundation

/// Everywhere the app writes to disk.
///
/// One place, because the alternative was found in the wild: the speech model
/// was landing in the user's **Documents** folder, 616MB of CoreML weights next
/// to their own files and syncing to iCloud Drive. Anything regenerable belongs
/// under Application Support, and nothing outside this type should be
/// constructing paths.
enum AppPaths {

    /// `~/Library/Application Support/com.sukrit.notchvoice`.
    ///
    /// Keyed on the bundle identifier rather than the display name, matching the
    /// TCC grants and `UserDefaults`, both of which key on the same thing.
    static let support: URL = {
        let identifier = Bundle.main.bundleIdentifier ?? "com.sukrit.notchvoice"
        return URL.applicationSupportDirectory
            .appending(path: identifier, directoryHint: .isDirectory)
    }()

    /// Speech model weights and tokenizers.
    static var models: URL {
        support.appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Weights for the optional cleanup model.
    ///
    /// Kept apart from `models` rather than beside the speech model, because
    /// this one is deleted on request and "remove the cleanup model" must not be
    /// able to take transcription down with it.
    static var cleanupModel: URL {
        support.appending(path: "CleanupModel", directoryHint: .isDirectory)
    }

    /// The SwiftData store holding transcripts, custom words and snippets.
    ///
    /// Never audio — recordings are discarded the moment they are transcribed.
    static var history: URL {
        support.appending(path: "History.store", directoryHint: .notDirectory)
    }

    /// Creates a directory if it is not there. Throws rather than returning a
    /// path that cannot be written to.
    static func ensure(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
