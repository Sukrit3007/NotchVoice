import Testing
@testable import NotchVoiceCore

@Suite("ClipboardGuard")
struct ClipboardGuardTests {

    @Test("restores when nothing else touched the clipboard")
    func restoresWhenUntouched() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 42) == true)
    }

    @Test("skips restore when something else wrote in the meantime")
    func skipsWhenClobbered() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 43) == false)
    }

    @Test("skips restore when the change count could not be read")
    func skipsWhenUnknown() {
        // Unknown state is safer than an unconditional overwrite: the user's
        // newer clipboard content is worth more than our snapshot.
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: nil) == false)
    }

    @Test("a lower change count is still treated as a mismatch")
    func skipsOnLowerCount() {
        #expect(ClipboardGuard.shouldRestore(
            changeCountAfterWrite: 42, currentChangeCount: 41) == false)
    }
}
