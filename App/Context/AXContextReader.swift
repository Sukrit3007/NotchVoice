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
///    keypress. The messaging timeout below bounds that.
@MainActor
enum AXContextReader {

    /// How long to wait on the focused app before giving up.
    ///
    /// Context is an enhancement; a dictation must never be slower because the
    /// app being dictated into is busy. Missing it costs a little accuracy,
    /// waiting on it costs the whole interaction.
    private static let timeout: Float = 0.25

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
    /// element, a secure field, an unreadable app, a field with nothing in it —
    /// so the caller has one case to handle instead of five.
    static func focusedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)

        guard let focused = copyElement(from: system, attribute: kAXFocusedUIElementAttribute)
        else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)

        // Checked before the value is requested, not after. Asking a password
        // field for its contents and then discarding them is still asking.
        if let role = copyString(from: focused, attribute: kAXRoleAttribute),
           refusedRoles.contains(role) {
            return nil
        }

        guard let value = copyString(from: focused, attribute: kAXValueAttribute),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return value
    }

    // MARK: - AX plumbing

    private static func copyElement(
        from element: AXUIElement, attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return nil }
        // `CFGetTypeID` rather than a conditional cast: the attribute is typed
        // `CFTypeRef` and an `as?` to `AXUIElement` succeeds for values that are
        // not one.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(from element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }
}
