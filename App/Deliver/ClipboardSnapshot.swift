import AppKit

/// Full-fidelity snapshot of the general pasteboard.
///
/// Stores every `(UTI, raw bytes)` pair on every item, so restoring rebuilds
/// the complete multi-type payload — images, styled text, and file references
/// all survive the round-trip, not just the plain-text fallback.
struct ClipboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    static func capture() -> ClipboardSnapshot {
        let captured = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
        return ClipboardSnapshot(items: captured)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let rebuilt = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        // The clipboard has already been cleared at this point, so a failed
        // write leaves the user with an empty clipboard — the exact outcome
        // this type exists to prevent. Nothing can be done to recover it, but
        // it must not pass silently.
        if !pasteboard.writeObjects(rebuilt) {
            Log.deliver.error(
                "Clipboard restore FAILED — \(rebuilt.count, privacy: .public) item(s) lost")
        }
    }
}
