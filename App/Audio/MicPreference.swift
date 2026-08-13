import Foundation

/// Which microphone to record from.
///
/// Stored as a **UID**, not an `AudioDeviceID`. CoreAudio reuses numeric IDs
/// across reconnects, so a stored ID can start pointing at a different device
/// after an interface is unplugged — and the app would record from the wrong
/// thing without anything looking wrong.
///
/// Absent means "follow the system", which is the right default and also the
/// right fallback: a chosen device that is no longer attached resolves to nil
/// and capture continues on whatever the Mac is using.
enum MicPreference {
    private static let key = "microphoneUID"

    /// Nil when following the system default.
    static var uid: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// The device to record from, and whether the user's choice was honoured.
    ///
    /// Returns the fallback rather than failing: a missing microphone is a
    /// reason to warn, not a reason to lose the dictation.
    static func resolve() -> (device: AudioDevices.Device?, wasMissing: Bool) {
        guard let uid else { return (AudioDevices.systemDefault(), false) }
        if let chosen = AudioDevices.device(uid: uid) { return (chosen, false) }
        return (AudioDevices.systemDefault(), true)
    }
}
