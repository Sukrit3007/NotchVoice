import Testing
@testable import NotchVoiceCore

@Suite("KeyCodeLookup")
struct KeyCodeLookupTests {

    // Fragments of real layouts, by virtual keycode.
    let qwerty: [UInt16: String] = [9: "v", 40: "k", 47: "."]
    let dvorak: [UInt16: String] = [9: "k", 40: "t", 47: "v"]
    let cyrillic: [UInt16: String] = [9: "м", 40: "л", 47: "ю"]

    @Test("QWERTY finds V where it is printed")
    func qwertyV() {
        #expect(KeyCodeLookup.keyCode(typing: "v") { qwerty[$0] } == 9)
    }

    @Test("Dvorak finds the key that types v, not the one labelled V")
    func dvorakV() {
        #expect(KeyCodeLookup.keyCode(typing: "v") { dvorak[$0] } == 47)
    }

    @Test("a layout with no v has no answer, so the caller falls back")
    func noV() {
        #expect(KeyCodeLookup.keyCode(typing: "v") { cyrillic[$0] } == nil)
    }

    @Test("case does not matter")
    func caseInsensitive() {
        #expect(KeyCodeLookup.keyCode(typing: "v") { $0 == 9 ? "V" : nil } == 9)
    }

    @Test("keys that type nothing are skipped")
    func untranslatableKeys() {
        #expect(KeyCodeLookup.keyCode(typing: "v") { $0 == 47 ? "v" : nil } == 47)
    }
}
