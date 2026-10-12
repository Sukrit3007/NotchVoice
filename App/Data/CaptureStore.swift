import Foundation
import NotchVoiceCore
import SwiftData

/// Everything the app *writes* to the store, off the main actor.
///
/// Reads for the UI deliberately do not live here: `@Query` in a view is the
/// idiomatic path and stays live as rows change, where anything returned from
/// this actor would be a snapshot that silently goes stale. What does live here
/// is writing — which must not happen on the main actor while a dictation is
/// finishing — and aggregates, which `@Query` cannot express.
///
/// `@Model` types are not `Sendable`, so nothing crosses this boundary as a
/// model object. Writes take a plain value, reads return one.
@ModelActor
actor CaptureStore {

    // MARK: - Writing

    /// Records a delivered dictation.
    ///
    /// Called after delivery, never before: a row here means the words reached
    /// the user, not that they held the key.
    func record(_ draft: CaptureDraft) throws {
        modelContext.insert(draft.model())
        try modelContext.save()
    }

    /// Applies a dictionary rewrite count. Separate from `record` because a
    /// transcript can trigger several, and a failure to count one must not lose
    /// the transcript.
    func noteDictionaryUse(phrase: String) throws {
        let descriptor = FetchDescriptor<DictionaryEntry>(
            predicate: #Predicate { $0.phrase == phrase }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.timesApplied += 1
        try modelContext.save()
    }

    // MARK: - Reading

    func captureCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Capture>())
    }

    /// Terms to suggest to the decoder before it transcribes.
    ///
    /// Starred first, because the prompt has a budget and the user has already
    /// said which words matter most.
    func biasTerms() throws -> [String] {
        let entries = try modelContext.fetch(FetchDescriptor<DictionaryEntry>())
        return entries
            .sorted { ($0.isStarred ? 0 : 1, $0.phrase) < ($1.isStarred ? 0 : 1, $1.phrase) }
            .map(\.phrase)
    }

    /// The rewrites of one kind to run over a transcript.
    ///
    /// The same operation, run at two different points: corrections before
    /// polish, snippets after it — see `DictationCoordinator`.
    func rewriteRules(_ kind: RewriteKind) throws -> [TranscriptRewriter.Rule] {
        switch kind {
        case .corrections:
            return try modelContext.fetch(FetchDescriptor<DictionaryEntry>()).compactMap { entry in
                guard let misheard = entry.misheardAs, !misheard.isEmpty else { return nil }
                return TranscriptRewriter.Rule(match: misheard, replacement: entry.phrase)
            }
        case .snippets:
            return try modelContext.fetch(FetchDescriptor<Snippet>()).map {
                TranscriptRewriter.Rule(match: $0.trigger, replacement: $0.expansion)
            }
        }
    }

    /// Records that a rewrite fired, against whichever kind of rule it was.
    func noteRewrites(_ matches: [String]) throws {
        guard !matches.isEmpty else { return }
        let entries = try modelContext.fetch(FetchDescriptor<DictionaryEntry>())
        let snippets = try modelContext.fetch(FetchDescriptor<Snippet>())

        for match in matches {
            if let entry = entries.first(where: { $0.misheardAs == match }) {
                entry.timesApplied += 1
            } else if let snippet = snippets.first(where: { $0.trigger == match }) {
                snippet.timesUsed += 1
            }
        }
        try modelContext.save()
    }

    /// Totals across every capture.
    ///
    /// Derived from `Capture` rather than kept in a rolling counter table.
    /// A counter is a second source of truth that drifts the first time a row is
    /// deleted, and at the volumes one person generates this is a cheap scan.
    ///
    /// The Stats pane does **not** call this — it uses `@Query` so the numbers
    /// move as rows arrive. Both go through `CaptureTotals.of` so there is one
    /// implementation of the arithmetic.
    func totals() throws -> CaptureTotals {
        CaptureTotals.of(try modelContext.fetch(FetchDescriptor<Capture>()))
    }

    // MARK: - Deleting

    /// Removes every transcript. The dictionary and snippets are deliberately
    /// left alone — they are settings the user built up, not history.
    func deleteAllCaptures() throws {
        try modelContext.delete(model: Capture.self)
        try modelContext.save()
    }
}

enum RewriteKind: Sendable {
    /// Dictionary entries with a misheard form: what the model got wrong.
    case corrections
    /// Snippet triggers: shorthand the user said on purpose.
    case snippets
}

/// A capture before it exists — plain values, so it can cross into the actor.
struct CaptureDraft: Sendable {
    var text: String
    var rawText: String?
    var durationSeconds: Double
    var language: String
    var targetBundleID: String?
    var targetAppName: String?
    var micDevice: String?
    var modelVariant: String

    func model() -> Capture {
        Capture(
            text: text,
            rawText: rawText,
            durationSeconds: durationSeconds,
            language: language,
            targetBundleID: targetBundleID,
            targetAppName: targetAppName,
            micDevice: micDevice,
            modelVariant: modelVariant
        )
    }
}

struct CaptureTotals: Sendable, Equatable {
    var captures: Int
    var words: Int
    var seconds: Double

    /// Nonisolated so both callers can use it: the store reads its own fetch
    /// inside the actor, the Stats pane reads a `@Query` result on the main
    /// actor, and each stays in its own isolation domain.
    static func of(_ captures: [Capture]) -> CaptureTotals {
        CaptureTotals(
            captures: captures.count,
            words: captures.reduce(0) { $0 + $1.wordCount },
            seconds: captures.reduce(0) { $0 + $1.durationSeconds }
        )
    }

    /// Average speaking rate across everything dictated. Nil before there is
    /// enough to average.
    var wordsPerMinute: Double? {
        guard seconds >= 1, words > 0 else { return nil }
        return Double(words) / (seconds / 60)
    }
}
