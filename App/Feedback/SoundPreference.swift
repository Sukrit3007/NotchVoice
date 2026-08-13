import Foundation

/// Whether the feedback cues play.
///
/// Sound is the most taste-dependent thing this app does, and it is the one
/// piece of it that follows the user into a meeting. It should be switchable
/// without a rebuild.
enum SoundPreference {
    private static let key = "playSounds"

    static var isEnabled: Bool {
        get {
            // `object(forKey:)` rather than `bool(forKey:)`: the latter returns
            // false for an absent key, which would ship the app silent by
            // default. Absent means "never set", and the default is on.
            guard let stored = UserDefaults.standard.object(forKey: key) as? Bool
            else { return true }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
