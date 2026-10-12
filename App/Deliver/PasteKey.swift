import Carbon.HIToolbox
import CoreGraphics
import NotchVoiceCore

/// The physical key that types "v" on the keyboard layout in use, for the
/// synthetic ⌘V.
///
/// `kVK_ANSI_V` (9) is where V sits on QWERTY. On Dvorak that key types K, so a
/// hard-coded 9 posts ⌘K; Colemak, Workman and several national layouts move V
/// too. Apps match a shortcut by the character its key types *with ⌘ held*, so
/// that is what is looked up — layouts such as "Dvorak – QWERTY ⌘" switch to
/// QWERTY while ⌘ is down, and translating with ⌘ gets them right as well.
///
/// Main actor: the Text Input Sources API expects the main thread.
@MainActor
enum PasteKey {

    /// Where V sits on QWERTY, and the answer when no key on the current
    /// layout types "v" — the non-Latin layouts without a ⌘ table, where the
    /// QWERTY position is what ⌘-shortcuts use.
    static let fallback: CGKeyCode = 9

    /// Looked up on every paste rather than cached: it is 128 table lookups,
    /// and the user can switch layout between two dictations.
    static func current() -> CGKeyCode {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let code = keyCode(in: source)
        else { return fallback }
        return code
    }

    private static func keyCode(in source: TISInputSource) -> CGKeyCode? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let keyboardType = UInt32(LMGetKbdType())
        let commandHeld = UInt32((cmdKey >> 8) & 0xFF)

        return KeyCodeLookup.keyCode(typing: "v") { code in
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, code, UInt16(kUCKeyActionDown), commandHeld, keyboardType,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
