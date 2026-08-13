import Foundation

/// Whether the app reads the text field it is dictating into.
///
/// Switchable because it is the one part of this app that looks at something the
/// user did not hand it directly. Nothing leaves the Mac and nothing is stored —
/// the text is turned into a prompt for a local model and dropped, and `Capture`
/// has no field to keep it in — but "it only reads what is already on your
/// screen" is a sentence some people will want a switch next to.
///
/// Default on. It is the largest accuracy gain the app has without a language
/// model, and a setting nobody finds is a feature nobody gets.
enum ContextPreference {
    private static let key = "readScreenContext"

    static var isEnabled: Bool {
        get {
            // `object(forKey:)` rather than `bool(forKey:)`: the latter reports
            // false for an absent key, which would ship the feature off.
            guard let stored = UserDefaults.standard.object(forKey: key) as? Bool
            else { return true }
            return stored
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
