/// A bindable key, identified by its macOS virtual keycode.
///
/// `fn` is the default and the only non-modifier here. It earns the exception by
/// being the one key on a Mac keyboard that types nothing in any combination —
/// which is what lets the island appear the instant it goes down, with no
/// settling delay to guard against `⌥ + o` typing `ø`.
///
/// Only viable because the tap consumes it — a `.listenOnly` tap would let fn
/// through and open the emoji picker on every dictation. See `ModifierTap`.
///
/// The remaining four are right-hand modifiers. Left-hand variants collide with
/// the shortcuts people already use — see the design spec, §4.
public enum ModifierKey: UInt16, CaseIterable, Codable, Sendable {
    case fn = 63
    case rightCommand = 54
    case rightShift = 60
    case rightOption = 61
    case rightControl = 62

    public static let `default`: ModifierKey = .fn

    /// What to bind when the keyboard in use has no fn key.
    ///
    /// External non-Apple keyboards do not have one, and binding to a key that
    /// physically cannot be pressed is a silently dead app. `KeyboardCapabilities`
    /// detects the case; this is where it lands.
    public static let fallback: ModifierKey = .rightOption

    /// Whether this binding depends on a key only Apple keyboards carry.
    public var needsFnKey: Bool { self == .fn }

    public var displayName: String {
        switch self {
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        case .rightShift: "Right ⇧"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }
}
