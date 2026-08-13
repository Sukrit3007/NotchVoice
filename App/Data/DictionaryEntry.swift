import Foundation
import SwiftData

/// A word the speech model keeps getting wrong.
///
/// Two jobs, and they are separate on purpose:
///
/// - **Bias.** The phrase is fed to the decoder as a prompt so it is more likely
///   to be heard in the first place. This is the one that actually fixes names
///   and jargon.
/// - **Replace.** When bias is not enough, `replacement` rewrites the output
///   afterwards. A blunt instrument — it fires on text the user did say — so it
///   is opt-in per entry rather than implied by adding a word.
@Model
final class DictionaryEntry {

    /// The term as it should come out. Unique so the list cannot accumulate the
    /// same word twice — the app is not using CloudKit, where `.unique` is
    /// forbidden.
    @Attribute(.unique) var phrase: String

    /// What the model hears instead, rewritten to `phrase` after transcription.
    /// Nil means bias only.
    var misheardAs: String?

    /// Pinned to the top of the list.
    var isStarred: Bool

    var createdAt: Date

    /// How often the replacement has fired. Zero on a long-lived entry is a
    /// signal the bias alone was enough and the rewrite can go.
    var timesApplied: Int

    init(
        phrase: String,
        misheardAs: String? = nil,
        isStarred: Bool = false,
        createdAt: Date = .now,
        timesApplied: Int = 0
    ) {
        self.phrase = phrase
        self.misheardAs = misheardAs
        self.isStarred = isStarred
        self.createdAt = createdAt
        self.timesApplied = timesApplied
    }

    var rewrites: Bool { !(misheardAs ?? "").isEmpty }
}
