import Foundation

/// Generates the short tones used as feedback cues.
///
/// Two properties do almost all the work of making a cue pleasant, and both are
/// asserted in `ToneTests`:
///
/// - **The attack.** A tone that starts at full amplitude produces a
///   discontinuity, and a discontinuity is a click. Every tone here opens on a
///   raised-cosine ramp, so it begins at exactly zero and arrives smoothly.
/// - **The amplitude.** A cue that fires on every dictation has to be quiet
///   enough to live with. These peak below 0.08.
public enum Tone {

    public static let sampleRate: Double = 44_100

    /// Level of the second harmonic, relative to the fundamental.
    ///
    /// A pure sine is the smoothest possible waveform and sounds thin for it. A
    /// little energy at 2f reads as warmth — closer to a soft mallet than a test
    /// tone — without the upper harmonics that make a sound feel sharp.
    public static let defaultHarmonic: Float = 0.15

    /// One note.
    ///
    /// - Parameters:
    ///   - frequency: fundamental, in Hz.
    ///   - duration: total length including the decay tail, in seconds.
    ///   - attack: rise time, in seconds. Below about 0.01 the onset is heard as
    ///     a tick.
    ///   - decay: seconds from the peak down to a tenth of it. This is what
    ///     separates a blip from a tone, and it is deliberately *not*
    ///     proportional to `duration` — a single decay rate applied to every cue
    ///     made the short ones linger, which is what makes a frequent sound
    ///     wearing.
    ///   - amplitude: peak level.
    public static func render(
        frequency: Double,
        duration: Double,
        attack: Double,
        decay: Double,
        amplitude: Float,
        harmonic: Float = defaultHarmonic
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        guard count > 1, frequency > 0, amplitude > 0, decay > 0 else { return [] }

        let attackSamples = max(1, min(Int(attack * sampleRate), count - 1))
        let decaySamples = max(1.0, decay * sampleRate)
        // exp(-k) = 0.1 after `decaySamples`, so k = ln(10) per decay length.
        let k = log(10.0) / decaySamples
        let omega = 2 * Double.pi * frequency / sampleRate

        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let phase = omega * Double(i)
            let wave = sin(phase) + Double(harmonic) * sin(2 * phase)
            // Normalised so adding the harmonic cannot push the peak above the
            // requested amplitude — otherwise `harmonic` would secretly be a
            // volume control as well as a timbre control.
            let value = wave / (1 + Double(harmonic))

            samples[i] = Float(value * envelope(at: i, attack: attackSamples, k: k))
                * amplitude
        }

        // Pinned rather than trusted to the maths. The decay approaches zero
        // without reaching it, and a final sample of even 0.001 is a step to
        // silence — the click this type exists to avoid.
        samples[0] = 0
        samples[count - 1] = 0
        return samples
    }

    /// Two notes with a gap between them, for the lock cue. The gesture is a
    /// double tap, so the sound is a double tap.
    public static func pair(
        frequency: Double,
        duration: Double,
        gap: Double,
        attack: Double,
        decay: Double,
        amplitude: Float,
        harmonic: Float = defaultHarmonic
    ) -> [Float] {
        let note = render(
            frequency: frequency,
            duration: duration,
            attack: attack,
            decay: decay,
            amplitude: amplitude,
            harmonic: harmonic
        )
        guard !note.isEmpty else { return [] }
        let silence = [Float](repeating: 0, count: Int(gap * sampleRate))
        return note + silence + note
    }

    /// Raised-cosine rise, then exponential decay at a fixed rate per sample.
    ///
    /// The rate is absolute rather than scaled to the tone's length, so a cue
    /// can be short and snappy or long and lingering independently of how long
    /// its buffer runs.
    private static func envelope(at index: Int, attack: Int, k: Double) -> Double {
        if index < attack {
            let t = Double(index) / Double(attack)
            return 0.5 * (1 - cos(Double.pi * t))
        }
        return exp(-k * Double(index - attack))
    }
}
