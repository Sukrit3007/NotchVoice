import Testing
@testable import NotchVoiceCore

@Suite("RecordingStateMachine")
struct RecordingStateMachineTests {

    /// Drives a machine into `.locked` the way the tap does: key down, then
    /// Space while it is still held.
    private func locked() -> RecordingStateMachine {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.chordPressed)
        return sm
    }

    @Test("key down starts capture")
    func keyDownStartsCapture() {
        var sm = RecordingStateMachine()
        #expect(sm.handle(.keyDown(at: 0)) == .startCapture)
        #expect(sm.state == .holding(downAt: 0))
    }

    @Test("holding past the threshold then releasing transcribes")
    func longHoldTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.keyUp(at: 0.9)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("holding exactly at the threshold transcribes")
    func holdAtExactThresholdTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        // 0.4 - 0 is exact in floating point, so this pins the >= boundary.
        #expect(sm.handle(.keyUp(at: 0.4)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("a tap too short to be a hold is discarded immediately")
    func shortTapDiscards() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        // No double-tap window to wait out any more: this resolves on the
        // release rather than 300ms later.
        #expect(sm.handle(.keyUp(at: 0.1)) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("the chord locks hands-free")
    func chordLocks() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.chordPressed) == .enterLocked)
        #expect(sm.state == .locked)
    }

    @Test("releasing the key after the chord does not end the session")
    func keyUpAfterLockIsIgnored() {
        var sm = locked()
        #expect(sm.handle(.keyUp(at: 0.4)) == .none)
        #expect(sm.state == .locked)
    }

    @Test("tapping the key while locked stops and transcribes")
    func tapWhileLockedStops() {
        var sm = locked()
        #expect(sm.handle(.keyDown(at: 9.0)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("the chord arriving again while locked is ignored")
    func chordWhileLockedIsIgnored() {
        var sm = locked()
        #expect(sm.handle(.chordPressed) == .none)
        #expect(sm.state == .locked)
    }

    @Test("pressing another key while held cancels silently")
    func otherKeyCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.otherKeyPressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("typing while locked does not cancel — locked is deliberate")
    func otherKeyWhileLockedIsIgnored() {
        var sm = locked()
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.state == .locked)
    }

    @Test("escape while holding cancels")
    func escapeWhileHoldingCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.escapePressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("escape while locked cancels")
    func escapeWhileLockedCancels() {
        var sm = locked()
        #expect(sm.handle(.escapePressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("hitting the duration cap transcribes rather than discarding")
    func maxDurationTranscribes() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.maxDurationReached) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("hitting the duration cap while locked transcribes")
    func maxDurationWhileLockedTranscribes() {
        var sm = locked()
        #expect(sm.handle(.maxDurationReached) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("events arriving in the idle state are ignored")
    func idleIgnoresStrayEvents() {
        var sm = RecordingStateMachine()
        #expect(sm.handle(.keyUp(at: 1)) == .none)
        #expect(sm.handle(.chordPressed) == .none)
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.handle(.escapePressed) == .none)
        #expect(sm.handle(.maxDurationReached) == .none)
        #expect(sm.state == .idle)
    }

    @Test("the hold threshold is configurable")
    func customThreshold() {
        var sm = RecordingStateMachine(thresholds: .init(hold: 1.0))
        _ = sm.handle(.keyDown(at: 0))
        // 0.5s clears the default 0.4s threshold but not this one, so this can
        // only pass if the custom value is actually in effect.
        #expect(sm.handle(.keyUp(at: 0.5)) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("key-down auto-repeat while holding does not reset the hold")
    func keyDownAutoRepeatWhileHoldingIsIgnored() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.keyDown(at: 0.05)) == .none)
        // The original downAt must survive, not the repeat's timestamp.
        #expect(sm.state == .holding(downAt: 0))
    }
}
