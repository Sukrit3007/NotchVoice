import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import NotchVoiceCore

/// Cleanup through the downloaded 4B model.
///
/// Slower than Apple's by a factor of ten and worth it for one thing: speech
/// arrives as a single unbroken run of words, and deciding where the paragraphs
/// and lists go is the part a small model gets wrong.
actor LocalModelPolish: PolishBackend {

    nonisolated let name = "Local model"

    /// A backstop, not a target — a rewrite normally lands in two or three
    /// seconds. What this catches is a generation that has gone wrong and would
    /// otherwise leave the island saying "Tidying up" until the user gives up.
    ///
    /// MLX's generation loop checks `Task.isCancelled` between tokens, so
    /// missing the deadline actually stops the GPU work rather than merely
    /// abandoning its result.
    nonisolated let deadline = Duration.seconds(20)

    nonisolated let instructions = PolishInstructions.structured

    /// How long the weights stay resident after the last dictation.
    ///
    /// A compromise. Unloading immediately makes every dictation after a pause
    /// pay several seconds to read 2.3GB back off disk; never unloading means a
    /// menu-bar app holds 2.5GB forever because you dictated once this morning.
    private static let idleWindow = Duration.seconds(300)

    /// Caps MLX's buffer cache. Left unbounded it grows to whatever the largest
    /// generation needed and keeps it, which on top of the weights is enough to
    /// start swapping on an 8GB Mac.
    private static let gpuCacheLimit = 32 * 1024 * 1024

    /// Sampling is near-greedy: this is a rewrite, and temperature here shows up
    /// as phrasing the user did not say landing in their document.
    private static let temperature: Float = 0.2

    private var container: ModelContainer?
    private var idleTask: Task<Void, Never>?

    nonisolated var isAvailable: Bool {
        LocalPolishModel.isInstalled
    }

    /// Reads the weights into memory. Several seconds; call it before the user
    /// is waiting on it.
    func prepare() async throws {
        guard container == nil else { return }
        guard isAvailable else { throw PolishError.unavailable }

        MLX.Memory.cacheLimit = Self.gpuCacheLimit
        let started = ContinuousClock.now
        container = try await loadModelContainer(
            from: LocalPolishModel.directory,
            using: TransformersTokenizerLoader())
        Log.polish.notice(
            "Cleanup model loaded in \(started.duration(to: .now).seconds, privacy: .public)s")
    }

    func polish(_ text: String) async throws -> String {
        try await prepare()
        guard let container else { throw PolishError.unavailable }

        // A fresh session per dictation, deliberately. `ChatSession` accumulates
        // history, and two consecutive dictations are unrelated — carrying the
        // first into the second invites the model to continue it.
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: Self.tokenBudget(for: text),
                temperature: Self.temperature))

        let raw = try await session.respond(to: text)
        scheduleUnload()
        return PolishGuard.withoutReasoning(raw)
    }

    /// Roughly twice what a faithful rewrite of this text needs.
    ///
    /// English runs about four characters to the token, so `count / 4` is the
    /// expected output and `count / 2` leaves generous room for punctuation and
    /// list markers. The point is not to be tight — it is that a model which has
    /// started generating something other than a rewrite stops somewhere.
    private static func tokenBudget(for text: String) -> Int {
        max(128, text.count / 2)
    }

    /// Restarts the idle countdown. Called after every use, so the window is
    /// time since the last dictation rather than time since the model loaded.
    private func scheduleUnload() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleWindow)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Drops the weights. The next dictation reloads them.
    func unload() {
        guard container != nil else { return }
        container = nil
        idleTask?.cancel()
        idleTask = nil
        MLX.Memory.clearCache()
        Log.polish.notice("Cleanup model unloaded after idle")
    }
}

private extension Duration {
    /// Seconds to one decimal place, for logging.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
