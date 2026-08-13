import Foundation
import SwiftData

/// One dictation, after it was delivered.
///
/// **No audio.** The sample buffer is dropped the moment transcription returns,
/// which is what lets the app claim your voice is never written to disk without
/// an asterisk. The cost is that a capture can never be re-transcribed with a
/// better model — a trade taken deliberately.
///
/// Written after delivery rather than before, so a row existing means the text
/// reached the user, not merely that they held the key.
@Model
final class Capture {

    var createdAt: Date

    /// What was actually delivered — polished when polish ran and was
    /// plausible, raw otherwise.
    var text: String

    /// Whisper's output, kept **only when polish changed it**.
    ///
    /// Nil therefore means "polish did not run, or made no difference", which is
    /// the question worth answering when a transcript comes out wrong: was it
    /// misheard, or was it tidied into something the user did not say?
    var rawText: String?

    var durationSeconds: Double
    var wordCount: Int

    /// The decoder's language for this take. Stored per row because the setting
    /// is about to become user-facing, and old rows must keep their own answer.
    var language: String

    /// Where the text went. Nil when the paste was never consumed and it only
    /// reached the clipboard.
    var targetBundleID: String?

    /// Resolved at capture time, not looked up later — an app that has since
    /// been uninstalled still has a name in the history.
    var targetAppName: String?

    /// Which microphone heard it. A take that came out empty and a take that
    /// came out wrong are different problems, and the input device is the first
    /// thing worth knowing about either.
    var micDevice: String?

    var modelVariant: String

    /// Hidden from the default history list without being deleted.
    var isArchived: Bool

    init(
        createdAt: Date = .now,
        text: String,
        rawText: String? = nil,
        durationSeconds: Double,
        language: String,
        targetBundleID: String? = nil,
        targetAppName: String? = nil,
        micDevice: String? = nil,
        modelVariant: String,
        isArchived: Bool = false
    ) {
        self.createdAt = createdAt
        self.text = text
        // Stored rather than computed: `@Query` cannot sort or filter on a
        // computed property, and "longest dictation" is a stat the app owes.
        self.wordCount = Capture.countWords(text)
        self.rawText = rawText
        self.durationSeconds = durationSeconds
        self.language = language
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.micDevice = micDevice
        self.modelVariant = modelVariant
        self.isArchived = isArchived
    }

    /// Words as a person would count them.
    ///
    /// Splitting on `" "` is the obvious version and it is wrong: it counts a
    /// dictated paragraph with newlines in it as one word, and a tab-separated
    /// line as one. Any whitespace separates.
    static func countWords(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// True when polish produced something different from what was heard.
    var wasPolished: Bool { rawText != nil }

    /// Words per minute for this take. Nil when it was too short to mean
    /// anything — a 0.4s capture extrapolates to a nonsense rate.
    var wordsPerMinute: Double? {
        guard durationSeconds >= 1, wordCount > 0 else { return nil }
        return Double(wordCount) / (durationSeconds / 60)
    }
}
