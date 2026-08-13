import Foundation
import WhisperKit

enum TranscriptionError: Error {
    case notReady
    case empty
}

/// How far along getting the speech model is.
///
/// Two phases rather than one number, because the second half genuinely has no
/// measurable progress — CoreML compiling and prewarming reports nothing.
enum ModelPhase: Sendable, Equatable {
    /// Fraction of the download, 0...1.
    case downloading(Double)
    /// Downloaded; compiling and prewarming. No fraction exists for this.
    case loading
    case ready
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

    /// `nonisolated` so the coordinator can stamp it onto a capture without an
    /// `await` — it is set once at init and never changes.
    nonisolated let modelVariant: String

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

    init(model: SpeechModel = ModelPreference.current) {
        self.modelVariant = model.rawValue
    }

    /// What the decoder was told to expect, for the history row.
    ///
    /// Read at transcription time rather than captured at init: the setting can
    /// change between launches and every row should record its own answer.
    nonisolated static var language: String {
        LanguagePreference.current.code ?? "auto"
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
    /// Fetches the model if it is not cached, then loads it.
    ///
    /// Download and load are separate calls rather than one `download: true`
    /// config, because only the download can report progress. Rolled together,
    /// the app can say nothing at all for however long a 630MB fetch takes.
    ///
    /// The two phases are reported distinctly because they *are* distinct:
    /// downloading has a fraction, loading does not. A bar that fills to 90% and
    /// then sits there for twelve seconds while CoreML compiles is a worse lie
    /// than admitting the second half is unmeasured.
    func prepare(onPhase: @Sendable @escaping (ModelPhase) -> Void) async throws {
        guard pipe == nil else { return }

        try AppPaths.ensure(AppPaths.models)

        onPhase(.downloading(0))
        let folder = try await WhisperKit.download(
            variant: modelVariant,
            downloadBase: AppPaths.models,
            progressCallback: { progress in
                onPhase(.downloading(progress.fractionCompleted))
            }
        )

        onPhase(.loading)
        let config = WhisperKitConfig(
            model: modelVariant,
            downloadBase: AppPaths.models,
            // Points at what was just fetched, and `download: false` so this
            // cannot quietly re-fetch after the progress UI has moved on.
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        onPhase(.ready)
    }

    /// Transcribes, optionally biased toward a prompt.
    ///
    /// The prompt is read by Whisper as preceding context, which pulls its
    /// output toward the vocabulary in it — how custom words and on-screen
    /// context get fixed at the point they are *heard* rather than rewritten
    /// afterwards on a guess about what went wrong.
    func transcribe(_ samples: [Float], prompt: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriptionError.notReady }

        await acquire()
        defer { release() }

        // Tokenised here rather than by the caller: the token IDs are specific
        // to this pipeline's tokenizer, and a caller holding stale ones after a
        // model change would bias toward nonsense.
        let promptTokens = prompt.flatMap { text -> [Int]? in
            guard let tokenizer = pipe.tokenizer else { return nil }
            let tokens = tokenizer.encode(text: text)
            return tokens.isEmpty ? nil : tokens
        }

        // `detectLanguage` only means anything alongside a nil language, and a
        // nil language without it makes the decoder guess silently. The two move
        // together or not at all.
        let language = LanguagePreference.current.code

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
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
