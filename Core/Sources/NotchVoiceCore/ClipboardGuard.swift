/// Decides whether it is safe to put the user's original clipboard back after
/// a paste.
///
/// `NSPasteboard.changeCount` increments on every mutation from any process.
/// If it still matches the value recorded right after we staged our text,
/// nothing else wrote in the interim and the restore is safe. If it moved —
/// the user's own ⌘C, a clipboard manager, Universal Clipboard — their newer
/// content wins and we leave it alone.
public enum ClipboardGuard {
    public static func shouldRestore(
        changeCountAfterWrite: Int,
        currentChangeCount: Int?
    ) -> Bool {
        guard let current = currentChangeCount else { return false }
        return current == changeCountAfterWrite
    }
}
