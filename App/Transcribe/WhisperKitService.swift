import Foundation
import WhisperKit

enum TranscriptionError: Error {
    case notReady
    case empty
}

/// Owns the WhisperKit pipeline for the life of the process.
///
/// The model is loaded once at launch and kept resident, trading ~1GB of
/// permanent RAM for every dictation being fast (spec §4).
///
/// A second dictation submitted while the first is still decoding waits for it
/// rather than contending for the ANE. That queueing comes from the explicit
/// gate below — *not* from actor isolation, which cannot provide it.
actor WhisperKitService {

    private let modelVariant: String

    /// `nonisolated(unsafe)` because `WhisperKit` is a plain non-Sendable class
    /// and its `transcribe` is a nonisolated `async` method — it hops to the
    /// generic executor, so calling it on `self`-isolated storage is "sending a
    /// non-Sendable value out of the actor" and Swift 6 rejects it outright.
    ///
    /// Do not read the annotation as "safe": it is unchecked, and what makes
    /// the use safe is the decode gate below. Without that gate two dictations
    /// can decode on this one pipeline at once (reasoned from actor
    /// reentrancy, not yet reproduced under load).
    private nonisolated(unsafe) var pipe: WhisperKit?

    /// Actor isolation cannot serialise decoding, because actors are reentrant:
    /// `transcribe` releases the actor at its `await` and the next dictation
    /// walks straight in. This is reachable, not theoretical —
    /// `RecordingStateMachine` has no transcribing state, so after
    /// `.stopAndTranscribe` it returns to `.idle` and a second hold arrives
    /// mid-decode whenever two sentences are dictated back to back. The
    /// invariant lives here rather than in the coordinator because this type
    /// owns the pipeline, and a caller cannot be relied on to remember.
    private var isDecoding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(modelVariant: String = "openai_whisper-large-v3-v20240930_turbo_632MB") {
        self.modelVariant = modelVariant
    }

    /// Takes the decode baton, suspending if another decode holds it.
    private func acquire() async {
        guard isDecoding else { isDecoding = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Passes the baton straight to the next waiter, or drops it if none.
    private func release() {
        if waiting.isEmpty { isDecoding = false }
        else { waiting.removeFirst().resume() }
    }

    var isReady: Bool { pipe != nil }

    /// Downloads the model if it isn't cached, loads it, and prewarms the
    /// compute units. Safe to call more than once; later calls no-op.
    func prepare(progress: @Sendable @escaping (Double) -> Void) async throws {
        guard pipe == nil else { return }

        let config = WhisperKitConfig(
            model: modelVariant,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        pipe = try await WhisperKit(config)
        progress(1.0)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriptionError.notReady }

        await acquire()
        defer { release() }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )

        let results = try await pipe.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw TranscriptionError.empty }
        return text
    }
}
