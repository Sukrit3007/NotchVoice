import Foundation

/// The four cues the app ships, as parameters rather than as audio files.
///
/// Pitched as one family — A4, D5, E5, A5 — so the set sounds like it belongs
/// to a single app rather than four unrelated beeps. The recording pair rises
/// and falls (D5 opening, A4 closing) and delivery resolves an octave above the
/// close, which is what makes "it worked" land without a word being said.
public enum CueSet {

    public struct Cue: Sendable {
        public let fileName: String
        public let samples: [Float]
    }

    public static var all: [Cue] {
        [
            Cue(fileName: "cue-start", samples: start),
            Cue(fileName: "cue-processing", samples: processing),
            Cue(fileName: "cue-locked", samples: locked),
            Cue(fileName: "cue-delivered", samples: delivered),
        ]
    }

    /// Capture is live. D5 — the highest of the two recording cues, so opening
    /// and closing are distinguishable without looking.
    public static var start: [Float] {
        Tone.render(
            frequency: 587.33, duration: 0.16,
            attack: 0.022, decay: 0.030, amplitude: 0.075
        )
    }

    /// Key released, decoding has begun. A4, below the start cue.
    public static var processing: [Float] {
        Tone.render(
            frequency: 440.00, duration: 0.15,
            attack: 0.020, decay: 0.028, amplitude: 0.070
        )
    }

    /// Hands-free session began. Two taps, mirroring the gesture.
    public static var locked: [Float] {
        Tone.pair(
            frequency: 659.25, duration: 0.075, gap: 0.055,
            attack: 0.018, decay: 0.018, amplitude: 0.070
        )
    }

    /// Transcript delivered. A5 — an octave above the closing cue, so the loop
    /// resolves.
    public static var delivered: [Float] {
        Tone.render(
            frequency: 880.00, duration: 0.17,
            attack: 0.016, decay: 0.035, amplitude: 0.065
        )
    }
}
