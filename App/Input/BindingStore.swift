import Foundation
import NotchVoiceCore

/// Persists which modifier is bound to dictation.
enum BindingStore {
    private static let key = "dictationBinding"

    static var binding: ModifierKey {
        get {
            // `UInt16(exactly:)`, not `UInt16(_:)`: the stored value is
            // user-writable (`defaults write … dictationBinding -1`) and the
            // plain initialiser traps on anything out of range, crashing the
            // app at launch. Out-of-range falls back to the default instead.
            guard let raw = UserDefaults.standard.object(forKey: key) as? Int,
                  let code = UInt16(exactly: raw),
                  let parsed = ModifierKey(rawValue: code)
            else {
                return .default
            }
            return parsed
        }
        set {
            UserDefaults.standard.set(Int(newValue.rawValue), forKey: key)
        }
    }
}
