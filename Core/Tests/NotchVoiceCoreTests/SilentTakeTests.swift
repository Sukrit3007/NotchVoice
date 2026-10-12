import Testing
@testable import NotchVoiceCore

@Suite("SilentTake")
struct SilentTakeTests {

    @Test("digital silence and an empty take are silent")
    func nothing() {
        #expect(SilentTake.isSilent([Float](repeating: 0, count: 16_000)))
        #expect(SilentTake.isSilent([]))
    }

    @Test("faint noise under the line is silent")
    func faintNoise() {
        let noise = (0 ..< 16_000).map { Float($0 % 7) * 0.001 - 0.003 }
        #expect(SilentTake.isSilent(noise))
    }

    @Test("one sample over the line is enough to decode")
    func anySignal() {
        // The take is decoded as soon as anything reaches the line, in either
        // direction: dropping speech is worse than decoding silence.
        var take = [Float](repeating: 0, count: 16_000)
        take[8_000] = -0.02
        #expect(!SilentTake.isSilent(take))
        #expect(!SilentTake.isSilent([SilentTake.peakThreshold]))
    }
}
