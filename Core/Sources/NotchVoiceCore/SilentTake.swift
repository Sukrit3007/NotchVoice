import Foundation

/// A take with no signal in it: the microphone delivered silence, or close to.
///
/// Whisper does not answer silence with nothing. On its own it says "you";
/// given a bias prompt it can say "Thank you.", "S." or the custom words
/// themselves, and WhisperKit has no no-speech check to stop it. So such a
/// take is not decoded at all, and comes back empty.
///
/// The line is the one `DictationCoordinator` already logs as effectively
/// silent: a peak under 0.01, which is -40 dBFS.
public enum SilentTake {

    public static let peakThreshold: Float = 0.01

    /// The loudest sample, as a magnitude.
    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    public static func isSilent(_ samples: [Float]) -> Bool {
        peak(samples) < peakThreshold
    }
}
