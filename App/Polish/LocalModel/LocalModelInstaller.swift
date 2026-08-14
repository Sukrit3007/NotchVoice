import Foundation
import Hub
import Observation

/// Gets the cleanup model onto disk, and off it again.
///
/// Separate from the backend that runs the model: this one is about bytes and a
/// progress bar, that one is about inference. Downloading 2.3GB is a thing the
/// user watches, so it lives on the main actor and is observed directly by the
/// Settings pane.
@MainActor
@Observable
final class LocalModelInstaller {

    /// Shared because there is one copy of the model on disk. Two installers
    /// would race for the same files and show two different progress bars for
    /// one download.
    static let shared = LocalModelInstaller()

    enum State: Equatable {
        case absent
        case downloading(Double)
        case installed
        /// Carries the reason, because "it didn't work" sends the user nowhere.
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        state = LocalPolishModel.isInstalled ? .installed : .absent
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func install() {
        guard !isDownloading else { return }
        state = .downloading(0)

        // Built here rather than inside the task: the relay has to capture a
        // real `self` to weakly reference, and inside the task there is only the
        // task's own weak capture to close over again.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                // Ignored once the download is over: `snapshot` can deliver a
                // last progress callback after it returns, and it would drop the
                // row from "Ready" back to 99%.
                guard let self, self.isDownloading else { return }
                self.state = .downloading(fraction)
            }
        }

        task = Task { [weak self] in
            do {
                try await Self.download(onProgress: report)
                guard let self else { return }
                // Asserted rather than assumed: a snapshot that returns without
                // the weights is a broken install that would otherwise only
                // surface as a load failure on the user's next dictation.
                self.state = LocalPolishModel.isInstalled
                    ? .installed
                    : .failed("The download finished but the model file is missing.")
                Log.polish.notice("Cleanup model installed")
            } catch {
                guard let self else { return }
                // Cancellation arrives as `CancellationError` or as a URLError,
                // depending on where in the transfer it landed. Neither is a
                // failure worth putting on screen — the user asked for it.
                guard !Task.isCancelled else {
                    self.state = LocalPolishModel.isInstalled ? .installed : .absent
                    return
                }
                Log.polish.error(
                    "Cleanup model download failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Fetches the snapshot, off the main actor.
    ///
    /// `HubApi`'s progress callback is not `@Sendable`, so one built on the main
    /// actor cannot be handed to a call that runs elsewhere. Building it here,
    /// where there is no isolation to leave, keeps that closure local and lets a
    /// plain `@Sendable` one carry the number back.
    private nonisolated static func download(
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try AppPaths.ensure(AppPaths.cleanupModel)
        let hub = HubApi(downloadBase: AppPaths.cleanupModel)
        _ = try await hub.snapshot(
            from: LocalPolishModel.repoID,
            matching: LocalPolishModel.filePatterns
        ) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    /// Stops the download. Part-downloaded files stay put, so resuming later
    /// picks up where this left off rather than starting the 2.3GB again.
    func cancel() {
        task?.cancel()
        task = nil
        state = LocalPolishModel.isInstalled ? .installed : .absent
    }

    /// Deletes the model and stops using it.
    ///
    /// Turning the preference off here is not tidiness — leaving it on would
    /// route the next dictation at a backend whose weights have just been
    /// deleted, and the cleanup would silently stop happening.
    func remove() {
        cancel()
        do {
            try LocalPolishModel.remove()
            LocalPolishPreference.isEnabled = false
            state = .absent
            Log.polish.notice("Cleanup model removed")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
