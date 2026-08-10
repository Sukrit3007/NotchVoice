/// A bindable modifier key, identified by its macOS virtual keycode.
///
/// Only right-hand modifiers are offered. Left-hand variants collide with the
/// shortcuts people already use, and non-modifier keys would require a
/// consuming event tap — see the design spec, §4.
public enum ModifierKey: UInt16, CaseIterable, Codable, Sendable {
    case rightCommand = 54
    case rightShift = 60
    case rightOption = 61
    case rightControl = 62

    public static let `default`: ModifierKey = .rightOption

    public var displayName: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightShift: "Right ⇧"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        }
    }
}
