import Foundation

/// The optional cleanup model: what it is, where it lives, and whether it is here.
///
/// One model rather than a picker. A choice between four language models is a
/// question nobody outside this repository can answer, and every extra option is
/// another 2GB somebody downloads to find out it was not the problem.
enum LocalPolishModel {

    /// An **instruct** variant, deliberately, not the `Qwen3-4B-4bit` hybrid.
    ///
    /// The hybrid reasons before answering, and reasoning about a transcript is
    /// both slow and dangerous here — the deliberation is text, and text is what
    /// gets pasted. `PolishGuard.withoutReasoning` is the backstop; picking a
    /// model with no thinking mode is the actual fix.
    static let repoID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    /// Shown before the user commits to the download. Measured from the repo,
    /// not estimated: 2.26GB of weights plus tokenizer files.
    static let approximateSize = "2.3 GB"

    /// Roughly what stays resident once loaded — weights plus working buffers.
    static let approximateMemory = "2.5 GB"

    /// Where `HubApi` lands the snapshot, given `AppPaths.cleanupModel` as its
    /// download base. The `models/` component is the Hub's own repo-type
    /// directory, not ours.
    static var directory: URL {
        AppPaths.cleanupModel
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: repoID, directoryHint: .isDirectory)
    }

    /// Only the files the model actually needs. Left unfiltered, the Hub also
    /// fetches the README and `.gitattributes`, which is harmless but means the
    /// progress bar is measuring a different set of files than the one the
    /// download page advertised.
    static let filePatterns = ["*.safetensors", "*.json", "*.jinja"]

    /// True when a usable model is on disk.
    ///
    /// Keyed on the weights rather than the directory: an interrupted download
    /// leaves the directory and its `.incomplete` files behind, and a folder
    /// existing is not the same as a model being in it.
    static var isInstalled: Bool {
        FileManager.default.fileExists(
            atPath: directory.appending(path: "model.safetensors").path)
    }

    /// Deletes the whole download base, `.incomplete` leftovers included.
    static func remove() throws {
        try FileManager.default.removeItem(at: AppPaths.cleanupModel)
    }

    /// What it is costing on disk right now, for the row that offers to delete it.
    ///
    /// Walks the tree rather than trusting `approximateSize`, so a half-finished
    /// download reports what it actually took rather than what it would have.
    static func bytesOnDisk() -> Int64 {
        let base = AppPaths.cleanupModel
        guard let files = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in files {
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += Int64(size ?? 0)
        }
        return total
    }
}

/// Whether to route cleanup through the downloaded model.
///
/// Separate from "is it installed" on purpose. Someone who downloads 2.3GB and
/// finds the extra couple of seconds per dictation not worth it should be able
/// to switch back without deleting it and having to fetch it again to change
/// their mind a second time.
enum LocalPolishPreference {
    private static let key = "usesLocalCleanupModel"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
