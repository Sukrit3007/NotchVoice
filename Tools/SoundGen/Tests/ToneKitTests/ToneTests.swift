import Testing
import Foundation
@testable import ToneKit

@Suite("Tone")
struct ToneTests {

    private func standard(
        frequency: Double = 440,
        duration: Double = 0.18,
        attack: Double = 0.028,
        decay: Double = 0.016,
        amplitude: Float = 0.09
    ) -> [Float] {
        Tone.render(
            frequency: frequency,
            duration: duration,
            attack: attack,
            decay: decay,
            amplitude: amplitude
        )
    }

    private func largestStep(_ s: [Float]) -> Float {
        var largest: Float = 0
        for i in 1..<s.count { largest = max(largest, abs(s[i] - s[i - 1])) }
        return largest
    }

    // MARK: - The click guarantees

    @Test("a tone begins and ends at exact silence")
    func endpointsAreSilent() {
        let s = standard()
        #expect(s.first == 0)
        #expect(s.last == 0)
    }

    @Test("no sample jumps far enough from the last one to click")
    func noDiscontinuities() {
        // The whole point of the file, stated numerically. A click is a step
        // change in amplitude; at 44.1kHz a 440Hz sine moves at most about
        // 0.0063 of its peak between samples, so anything an order of magnitude
        // above that is a discontinuity rather than a waveform.
        #expect(largestStep(standard()) < 0.01)
    }

    @Test("the highest cue in the set is also free of steps")
    func noDiscontinuitiesAtHighFrequency() {
        // Checked separately because a threshold that only holds at 440Hz would
        // pass here and mean nothing — a sine covers far more ground per sample
        // at 880Hz.
        #expect(largestStep(CueSet.delivered) < 0.01)
    }

    // MARK: - Envelope

    @Test("the attack rises without ever falling back")
    func attackIsMonotonic() {
        // Sampled on the envelope rather than the waveform: the carrier
        // oscillates, so peak-per-cycle is what has to climb.
        let s = standard(frequency: 440, duration: 0.18, attack: 0.028)
        let attackSamples = Int(0.028 * Tone.sampleRate)
        let window = Int(Tone.sampleRate / 440)   // one cycle

        var previous: Float = -1
        var i = 0
        while i + window < attackSamples {
            let peak = s[i..<(i + window)].map(abs).max() ?? 0
            #expect(peak >= previous)
            previous = peak
            i += window
        }
    }

    @Test("decay is an absolute time, not a fraction of the duration")
    func decayDoesNotScaleWithDuration() {
        // The bug this replaced: the decay rate was normalised over whatever
        // remained after the attack, so a longer cue decayed proportionally more
        // slowly — the difference between a blip and a lingering tone. Two cues
        // sharing a decay must reach a tenth at the same moment regardless of
        // length.
        func timeToTenth(_ s: [Float]) -> Int {
            let peak = s.map(abs).max() ?? 0
            let peakIndex = s.firstIndex { abs($0) >= peak * 0.99 } ?? 0
            let window = Int(Tone.sampleRate / 440)
            var i = peakIndex
            while i + window < s.count {
                if (s[i..<(i + window)].map(abs).max() ?? 0) < peak * 0.1 { return i - peakIndex }
                i += window
            }
            return s.count
        }

        let a = timeToTenth(standard(duration: 0.18, decay: 0.016))
        let b = timeToTenth(standard(duration: 0.48, decay: 0.016))
        #expect(abs(a - b) < Int(Tone.sampleRate * 0.005))   // within 5ms
    }

    @Test("the tail decays rather than stopping")
    func tailDecays() {
        let s = standard()
        let quarter = s.count / 4
        let early = s[quarter..<(quarter * 2)].map(abs).max() ?? 0
        let late = s[(quarter * 3)...].map(abs).max() ?? 0
        #expect(late < early)
    }

    // MARK: - Bounds

    @Test("no sample exceeds the requested amplitude")
    func amplitudeIsRespected() {
        // Load-bearing because the second harmonic is summed onto the
        // fundamental. Without normalising, `harmonic` would quietly raise the
        // volume as well as change the timbre.
        let amplitude: Float = 0.09
        #expect((standard(amplitude: amplitude).map(abs).max() ?? 0) <= amplitude + 1e-6)
    }

    @Test("a louder harmonic does not make the tone louder")
    func harmonicDoesNotRaiseLevel() {
        let plain = Tone.render(
            frequency: 440, duration: 0.18, attack: 0.028, decay: 0.016,
            amplitude: 0.09, harmonic: 0
        )
        let rich = Tone.render(
            frequency: 440, duration: 0.18, attack: 0.028, decay: 0.016,
            amplitude: 0.09, harmonic: 0.5
        )
        #expect(abs((plain.map(abs).max() ?? 0) - (rich.map(abs).max() ?? 0)) < 0.02)
    }

    @Test("length matches the requested duration")
    func lengthMatchesDuration() {
        #expect(standard(duration: 0.18).count == Int(0.18 * Tone.sampleRate))
        #expect(standard(duration: 0.46).count == Int(0.46 * Tone.sampleRate))
    }

    // MARK: - Degenerate input

    @Test("nonsense parameters produce silence rather than noise")
    func invalidInputIsEmpty() {
        #expect(Tone.render(frequency: 0, duration: 0.2, attack: 0.02, decay: 0.02, amplitude: 0.1).isEmpty)
        #expect(Tone.render(frequency: 440, duration: 0, attack: 0.02, decay: 0.02, amplitude: 0.1).isEmpty)
        #expect(Tone.render(frequency: 440, duration: 0.2, attack: 0.02, decay: 0.02, amplitude: 0).isEmpty)
    }

    @Test("an attack longer than the tone does not overrun it")
    func attackIsClampedToDuration() {
        // Guards an index-out-of-range as much as a sound: the attack length is
        // used directly as a sample offset.
        let s = Tone.render(frequency: 440, duration: 0.05, attack: 10, decay: 0.02, amplitude: 0.09)
        #expect(s.count == Int(0.05 * Tone.sampleRate))
        #expect(s.first == 0)
        #expect(s.last == 0)
    }

    // MARK: - The lock pair

    @Test("the lock cue is two notes separated by silence")
    func pairHasTwoNotesAndAGap() {
        let gap = 0.055, noteDuration = 0.075
        let s = CueSet.locked

        let noteSamples = Int(noteDuration * Tone.sampleRate)
        let gapSamples = Int(gap * Tone.sampleRate)
        #expect(s.count == noteSamples * 2 + gapSamples)

        // The gap really is silent, so the two taps read as separate.
        let middle = s[noteSamples..<(noteSamples + gapSamples)]
        #expect((middle.map(abs).max() ?? 1) == 0)
    }

    // MARK: - The shipped set

    @Test("every shipped cue is quiet, short, and click-free")
    func shippedCuesAreWellFormed() {
        for cue in CueSet.all {
            #expect(!cue.samples.isEmpty, "\(cue.fileName) is empty")
            #expect(cue.samples.first == 0, "\(cue.fileName) starts mid-waveform")
            #expect(cue.samples.last == 0, "\(cue.fileName) ends mid-waveform")
            #expect(largestStep(cue.samples) < 0.01, "\(cue.fileName) clicks")

            // A cue fires on every dictation. Loud or long is a cue you end up
            // turning off, which costs the feedback channel entirely.
            #expect((cue.samples.map(abs).max() ?? 0) <= 0.08, "\(cue.fileName) is too loud")
            let seconds = Double(cue.samples.count) / Tone.sampleRate
            #expect(seconds < 0.30, "\(cue.fileName) runs \(seconds)s")
        }
    }

    // MARK: - WAV encoding

    @Test("the encoded file is a well-formed 16-bit mono WAV")
    func wavHeaderIsValid() {
        let samples = standard()
        let data = WAV.encode(samples, sampleRate: Tone.sampleRate)

        #expect(data.prefix(4) == Data("RIFF".utf8))
        #expect(data[8..<12] == Data("WAVE".utf8))
        // 44-byte canonical header, then two bytes per sample.
        #expect(data.count == 44 + samples.count * 2)
    }
}
