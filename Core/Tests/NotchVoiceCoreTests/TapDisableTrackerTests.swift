import Testing
@testable import NotchVoiceCore

@Suite("TapDisableTracker")
struct TapDisableTrackerTests {

    @Test("an occasional disable is just re-enabled")
    func occasionalDisableDoesNotRebuild() {
        var tracker = TapDisableTracker(threshold: 3, window: 10)
        #expect(tracker.noteDisable(at: 0) == false)
        #expect(tracker.noteDisable(at: 20) == false)
        #expect(tracker.noteDisable(at: 40) == false)
    }

    @Test("a burst of disables asks for a rebuild")
    func burstRebuilds() {
        var tracker = TapDisableTracker(threshold: 3, window: 10)
        #expect(tracker.noteDisable(at: 0) == false)
        #expect(tracker.noteDisable(at: 2) == false)
        #expect(tracker.noteDisable(at: 4) == true)
    }

    @Test("counting starts afresh after a rebuild")
    func rebuildResetsCount() {
        var tracker = TapDisableTracker(threshold: 3, window: 10)
        _ = tracker.noteDisable(at: 0)
        _ = tracker.noteDisable(at: 1)
        #expect(tracker.noteDisable(at: 2) == true)
        #expect(tracker.noteDisable(at: 3) == false)
        #expect(tracker.noteDisable(at: 4) == false)
    }

    @Test("disables older than the window fall out of the count")
    func oldDisablesExpire() {
        var tracker = TapDisableTracker(threshold: 3, window: 10)
        _ = tracker.noteDisable(at: 0)
        _ = tracker.noteDisable(at: 1)
        #expect(tracker.noteDisable(at: 12) == false)
    }

    @Test("disables just after wake are not counted")
    func wakeGraceIgnoresDisables() {
        var tracker = TapDisableTracker(threshold: 3, window: 10, wakeGrace: 10)
        tracker.noteWake(at: 100)
        #expect(tracker.noteDisable(at: 101) == false)
        #expect(tracker.noteDisable(at: 102) == false)
        #expect(tracker.noteDisable(at: 103) == false)
        // Past the grace, counting resumes from zero.
        #expect(tracker.noteDisable(at: 111) == false)
        #expect(tracker.noteDisable(at: 112) == false)
        #expect(tracker.noteDisable(at: 113) == true)
    }
}
