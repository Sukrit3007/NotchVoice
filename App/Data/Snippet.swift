import Foundation
import SwiftData

/// A phrase that expands into something longer.
///
/// Distinct from `DictionaryEntry` even though both rewrite text, because the
/// intent is opposite: a dictionary entry fixes what the model *misheard*, a
/// snippet expands what the user *deliberately* said as shorthand. Merging them
/// would mean one list where half the rows are corrections and half are macros.
@Model
final class Snippet {

    /// What you say. Unique — two snippets on one trigger has no defined winner.
    @Attribute(.unique) var trigger: String

    /// What gets pasted instead.
    var expansion: String

    var createdAt: Date
    var timesUsed: Int

    init(
        trigger: String,
        expansion: String,
        createdAt: Date = .now,
        timesUsed: Int = 0
    ) {
        self.trigger = trigger
        self.expansion = expansion
        self.createdAt = createdAt
        self.timesUsed = timesUsed
    }
}
