import Testing
@testable import NotchVoiceCore

@Suite("LevelBuffer")
struct LevelBufferTests {

    @Test("starts empty-padded to capacity so bars render flat, not missing")
    func startsPadded() {
        let buffer = LevelBuffer(capacity: 4)
        #expect(buffer.levels == [0, 0, 0, 0])
    }

    @Test("appending scrolls values leftward")
    func appendScrolls() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.1)
        buffer.append(0.2)
        #expect(buffer.levels == [0, 0.1, 0.2])
    }

    @Test("oldest value drops off once capacity is exceeded")
    func dropsOldest() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.1)
        buffer.append(0.2)
        buffer.append(0.3)
        buffer.append(0.4)
        #expect(buffer.levels == [0.2, 0.3, 0.4])
    }

    @Test("levels are clamped into 0...1")
    func clampsLevels() {
        var buffer = LevelBuffer(capacity: 2)
        buffer.append(-5)
        buffer.append(9)
        #expect(buffer.levels == [0, 1])
    }

    @Test("reset returns to flat")
    func resetsToFlat() {
        var buffer = LevelBuffer(capacity: 3)
        buffer.append(0.9)
        buffer.reset()
        #expect(buffer.levels == [0, 0, 0])
    }

    @Test("rms of silence is zero")
    func rmsOfSilence() {
        #expect(LevelBuffer.rms([0, 0, 0, 0]) == 0)
    }

    @Test("rms of a constant signal is its magnitude")
    func rmsOfConstant() {
        let value = LevelBuffer.rms([0.5, -0.5, 0.5, -0.5])
        #expect(abs(value - 0.5) < 0.0001)
    }

    @Test("rms of an empty buffer is zero rather than NaN")
    func rmsOfEmpty() {
        #expect(LevelBuffer.rms([]) == 0)
    }
}
