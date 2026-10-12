import ApplicationServices
import AppKit

/// Reads the text already in the field being dictated into, to suggest to the
/// decoder before it transcribes.
///
/// This is the largest accuracy win available without a language model: the
/// names, jargon and spellings of whatever the user is actually working on are
/// usually already on screen, and nobody has to type them into a list first.
///
/// **Three things this must never do**, in order of how badly they would matter:
///
/// 1. **Read a password.** A secure text field is refused outright, by role,
///    before its value is ever requested.
/// 2. **Leave the Mac.** It does not: the prompt goes to a local model and is
///    never stored — `Capture` has no field for it.
/// 3. **Block the dictation.** Accessibility calls are synchronous IPC into
///    another process, and a busy or wedged app would otherwise hold up the
///    keypress. The read runs off the main thread, after the microphone has
///    started, and every call in it shares one `AXBudget`.
enum AXContextReader {

    /// How long the whole read may take, every call included.
    ///
    /// Context is an enhancement; a dictation must never be slower because the
    /// app being dictated into is busy. Missing it costs a little accuracy,
    /// waiting on it costs the whole interaction. Well inside the 0.4s hold
    /// threshold, so the text is in hand before the key comes back up.
    private static let budgetTotal: TimeInterval = 0.25

    /// No single call may take more than this, so a slow focus lookup still
    /// leaves time to read the field's value.
    private static let perCallCap: TimeInterval = 0.15

    /// Roles that are never read, whatever they contain.
    ///
    /// Spelled out rather than taken from a constant: `kAXSecureTextFieldRole`
    /// is not exposed to Swift, and the string is the stable part of the API
    /// anyway.
    private static let refusedRoles: Set<String> = [
        "AXSecureTextField",
    ]

    /// The text around the cursor, or nil when there is none worth having.
    ///
    /// Returns nil rather than an empty string for every refusal — no focused
    /// element, a secure field, an unreadable app, a field with nothing in it,
    /// a spent budget — so the caller has one case to handle instead of six.
    static func focusedText() -> String? {
        let budget = AX.budget(total: budgetTotal, perCallCap: perCallCap)
        let system = AXUIElementCreateSystemWide()

        guard let focused = AX.element(kAXFocusedUIElementAttribute, of: system, within: budget)
        else { return nil }

        // Checked before the value is requested, not after. Asking a password
        // field for its contents and then discarding them is still asking.
        if let role = AX.string(kAXRoleAttribute, of: focused, within: budget),
           refusedRoles.contains(role) {
            return nil
        }

        guard let value = AX.string(kAXValueAttribute, of: focused, within: budget),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return value
    }
}
