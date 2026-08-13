import AppKit
import Synchronization

/// Text staged on the pasteboard as a promise, so that reading it is observable.
///
/// `NSPasteboard.setString` hands over the bytes immediately and tells you
/// nothing afterwards, so ⌘V can only be reported as *posted*. An
/// `NSPasteboardItem` with a data provider inverts that: the pasteboard holds
/// only a declaration that a `.string` is available, and calls back the moment
/// some process actually asks for it. That callback is the proof.
///
/// The promise must outlive the paste. If this object is released while the
/// pasteboard still points at it, the data can never be provided — so `Paster`
/// holds it across the wait rather than letting it fall out of scope.
final class PastePromise: NSObject, NSPasteboardItemDataProvider {

    /// How often to re-check while waiting. See `waitForConsumption(within:)`.
    private static let pollInterval = Duration.milliseconds(10)

    private let text: String

    /// Behind a lock because AppKit calls the data provider on whichever thread
    /// requested the paste, not necessarily the main one. Hopping the write onto
    /// the main actor would delay the one signal this type exists to capture.
    private let consumed = Mutex<Bool>(false)

    var wasConsumed: Bool { consumed.withLock { $0 } }

    init(text: String) {
        self.text = text
        super.init()
    }

    /// Stages the promise and returns the resulting change count.
    ///
    /// The change count is handed to `ClipboardGuard` later to decide whether
    /// restoring the user's previous clipboard is safe — if anything else has
    /// written since, it is not.
    @MainActor
    func write() -> Int {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// Waits for some process to ask for the text.
    ///
    /// Polled rather than built on a continuation, deliberately: racing a
    /// `CheckedContinuation` against a sleep has to resume exactly once even
    /// when the timeout wins, and getting that wrong leaks or traps. This runs
    /// once per dictation for at most a quarter second, so twenty cheap
    /// wake-ups buy an implementation whose correctness is obvious.
    ///
    /// Main-actor isolated so `Paster` never hands this across an isolation
    /// boundary. The awaits suspend rather than block.
    @MainActor
    func waitForConsumption(within timeout: Duration) async -> Bool {
        var waited = Duration.zero
        while waited < timeout {
            if wasConsumed { return true }
            try? await Task.sleep(for: Self.pollInterval)
            waited += Self.pollInterval
        }
        return wasConsumed
    }

    // MARK: - NSPasteboardItemDataProvider

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // Being asked for the data *is* the signal. Recorded before the write so
        // that a consumer which somehow fails to take it still counts as having
        // asked — the question here is whether the target reached for the paste,
        // not whether it succeeded in rendering it.
        consumed.withLock { $0 = true }
        item.setString(text, forType: type)
    }
}
