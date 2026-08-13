import Foundation
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

    /// Totals across every capture, for the Stats pane.
    ///
    /// Derived from `Capture` rather than kept in a rolling counter table.
    /// A counter is a second source of truth that drifts the first time a row is
    /// deleted, and at the volumes one person generates this is a cheap scan.
    func totals() throws -> CaptureTotals {
        let captures = try modelContext.fetch(FetchDescriptor<Capture>())
        return CaptureTotals(
            captures: captures.count,
            words: captures.reduce(0) { $0 + $1.wordCount },
            seconds: captures.reduce(0) { $0 + $1.durationSeconds }
        )
    }

    // MARK: - Deleting

    /// Removes every transcript. The dictionary and snippets are deliberately
    /// left alone — they are settings the user built up, not history.
    func deleteAllCaptures() throws {
        try modelContext.delete(model: Capture.self)
        try modelContext.save()
    }
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

    /// Average speaking rate across everything dictated. Nil before there is
    /// enough to average.
    var wordsPerMinute: Double? {
        guard seconds >= 1, words > 0 else { return nil }
        return Double(words) / (seconds / 60)
    }
}
