import Testing
@testable import NotchVoiceCore

@Suite("RecordingStateMachine")
struct RecordingStateMachineTests {

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

    @Test("a quick tap waits for a second tap instead of transcribing")
    func quickTapArmsTimer() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.keyUp(at: 0.1)) == .armDoubleTapTimer)
        #expect(sm.state == .awaitingSecondTap(firstUpAt: 0.1))
    }

    @Test("double tap within the window locks")
    func doubleTapLocks() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.keyDown(at: 0.3)) == .enterLocked)
        #expect(sm.state == .locked)
    }

    @Test("a single tap with no follow-up is discarded")
    func singleTapDiscards() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.doubleTapWindowExpired) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("a second tap arriving too late starts a fresh hold")
    func lateSecondTapRestarts() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        #expect(sm.handle(.keyDown(at: 5.0)) == .startCapture)
        #expect(sm.state == .holding(downAt: 5.0))
    }

    @Test("pressing another key while held cancels silently")
    func otherKeyCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.otherKeyPressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("escape while holding cancels")
    func escapeWhileHoldingCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        #expect(sm.handle(.escapePressed) == .discard)
        #expect(sm.state == .idle)
    }

    @Test("tapping the key while locked stops and transcribes")
    func tapWhileLockedStops() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.keyDown(at: 9.0)) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("the key release that follows a locking tap is ignored")
    func keyUpAfterLockIsIgnored() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.keyUp(at: 0.4)) == .none)
        #expect(sm.state == .locked)
    }

    @Test("typing while locked does not cancel — locked is deliberate")
    func otherKeyWhileLockedIsIgnored() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.state == .locked)
    }

    @Test("escape while locked cancels")
    func escapeWhileLockedCancels() {
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
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
        var sm = RecordingStateMachine()
        _ = sm.handle(.keyDown(at: 0))
        _ = sm.handle(.keyUp(at: 0.1))
        _ = sm.handle(.keyDown(at: 0.3))
        #expect(sm.handle(.maxDurationReached) == .stopAndTranscribe)
        #expect(sm.state == .idle)
    }

    @Test("events arriving in the idle state are ignored")
    func idleIgnoresStrayEvents() {
        var sm = RecordingStateMachine()
        #expect(sm.handle(.keyUp(at: 1)) == .none)
        #expect(sm.handle(.otherKeyPressed) == .none)
        #expect(sm.handle(.escapePressed) == .none)
        #expect(sm.handle(.doubleTapWindowExpired) == .none)
        #expect(sm.state == .idle)
    }

    @Test("thresholds are configurable")
    func customThresholds() {
        var sm = RecordingStateMachine(
            thresholds: .init(hold: 1.0, doubleTap: 0.1)
        )
        _ = sm.handle(.keyDown(at: 0))
        // 0.5s is a long hold by default, but a short tap at this threshold
        #expect(sm.handle(.keyUp(at: 0.5)) == .armDoubleTapTimer)
    }
}
