/// Finds the physical key that types a character, by asking a keyboard layout
/// what each key produces.
///
/// A synthetic keystroke names a key, not a character, and which key types "v"
/// depends on the layout: QWERTY's V is Dvorak's K. Pure — the host supplies
/// the per-key lookup, which in the app wraps `UCKeyTranslate`.
public enum KeyCodeLookup {

    /// Virtual keycodes are seven bits.
    private static let keyCodes: Range<UInt16> = 0..<128

    /// The first key whose output matches `character`, ignoring case, or nil
    /// when no key on the layout types it.
    public static func keyCode(
        typing character: Character,
        translate: (UInt16) -> String?
    ) -> UInt16? {
        let target = String(character).lowercased()
        return keyCodes.first { translate($0)?.lowercased() == target }
    }
}
