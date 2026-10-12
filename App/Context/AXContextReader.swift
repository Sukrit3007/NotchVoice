import ApplicationServices
import AppKit
import NotchVoiceCore

/// Reads the text already in the field being dictated into, to suggest to the
/// decoder before it transcribes.
///
/// This is the largest accuracy win available without a language model: the
/// names, jargon and spellings of whatever the user is actually working on are
/// usually already on screen, and nobody has to type them into a list first.
/// The same read hands back the focused element itself, which delivery uses to
/// put focus back where the dictation started, and the text either side of the
/// caret, which delivery fits the dictation to.
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

    /// The focused element, its caret, and its text when `includingText`
    /// allows it.
    ///
    /// The element and caret are wanted even when the text is not: delivery
    /// uses them to put focus back on the field the dictation started in,
    /// exactly where the cursor was. Neither reads content — the caret is two
    /// numbers — and content is what the "Use what's on screen" switch governs.
    static func read(includingText: Bool) -> FocusedField? {
        let budget = AX.budget(total: budgetTotal, perCallCap: perCallCap)
        let system = AXUIElementCreateSystemWide()

        guard let focused = AX.element(kAXFocusedUIElementAttribute, of: system, within: budget)
        else { return nil }

        let role = AX.string(kAXRoleAttribute, of: focused, within: budget)
        // Only for a role known not to be a password field: even where the
        // caret sits in one says something about what was typed.
        let selection = role.map { !refusedRoles.contains($0) } == true
            ? AX.range(kAXSelectedTextRangeAttribute, of: focused, within: budget)
            : nil
        let value = includingText ? value(of: focused, role: role, within: budget) : nil
        return FocusedField(
            element: AXElement(raw: focused),
            selection: selection,
            text: value.flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            },
            surroundings: surroundings(of: focused, value: value, selection: selection, within: budget))
    }

    /// The field's whole value, or nil for every refusal — a secure field, an
    /// unreadable app, a spent budget.
    private static func value(
        of focused: AXUIElement, role: String?, within budget: AXBudget
    ) -> String? {
        // Checked before the value is requested, not after. Asking a password
        // field for its contents and then discarding them is still asking.
        if let role, refusedRoles.contains(role) {
            return nil
        }
        return AX.string(kAXValueAttribute, of: focused, within: budget)
    }

    /// The text either side of the caret, for fitting the dictation to it —
    /// see `InsertionRules`. Cut from the value already read, so it costs no
    /// call of its own, and only where the caret is known, which is only for
    /// a role known not to be a password field.
    private static func surroundings(
        of focused: AXUIElement, value: String?, selection: CFRange?, within budget: AXBudget
    ) -> InsertionRules.Surroundings? {
        guard let value, let selection else { return nil }
        // A field showing its placeholder can report it as its value, caret
        // at the start. Asked only then, so an ordinary read pays nothing.
        let placeholder = selection.location == 0 && !value.isEmpty
            ? AX.string(kAXPlaceholderValueAttribute, of: focused, within: budget)
            : nil
        return InsertionRules.Surroundings(
            value: value,
            selectionLocation: selection.location,
            selectionLength: selection.length,
            placeholder: placeholder)
    }
}

/// What had keyboard focus when the dictation key went down.
struct FocusedField: Sendable {
    let element: AXElement
    /// The caret, or the selected range. Nil when it could not be read.
    let selection: CFRange?
    /// Never stored, never sent anywhere.
    let text: String?
    /// The text either side of `selection`. Never stored, never sent
    /// anywhere, never logged.
    let surroundings: InsertionRules.Surroundings?
}
