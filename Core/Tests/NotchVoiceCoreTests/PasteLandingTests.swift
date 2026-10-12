import Testing
@testable import NotchVoiceCore

@Suite("PasteLanding")
struct PasteLandingTests {

    typealias State = PasteLanding.FieldState

    @Test("an insertion at the caret has landed")
    func insertionLands() {
        let before = State(characterCount: 10, selectionLocation: 4, selectionLength: 0)
        let after = State(characterCount: 15, selectionLocation: 9, selectionLength: 0)
        #expect(PasteLanding.verdict(before: before, after: after) == .landed)
    }

    @Test("replacing a selection of the same length still counts")
    func sameLengthReplacementLands() {
        // "hello" selected, "world" pasted: the length does not move, the
        // selection collapses to a caret after the new text.
        let before = State(characterCount: 20, selectionLocation: 3, selectionLength: 5)
        let after = State(characterCount: 20, selectionLocation: 8, selectionLength: 0)
        #expect(PasteLanding.verdict(before: before, after: after) == .landed)
    }

    @Test("a field that did not move at all did not take the paste")
    func unchangedFieldDidNotLand() {
        let state = State(characterCount: 10, selectionLocation: 4, selectionLength: 0)
        #expect(PasteLanding.verdict(before: state, after: state) == .notLanded)
    }

    @Test("a field that stays empty is not evidence either way")
    func emptyFieldIsUnknown() {
        // Google Docs takes a paste through a hidden input it keeps empty.
        let empty = State(characterCount: 0, selectionLocation: 0, selectionLength: 0)
        #expect(PasteLanding.verdict(before: empty, after: empty) == .unknown)
    }

    @Test("an unreadable field is not evidence either way")
    func unreadableIsUnknown() {
        let state = State(characterCount: 10, selectionLocation: 4, selectionLength: 0)
        #expect(PasteLanding.verdict(before: nil, after: state) == .unknown)
        #expect(PasteLanding.verdict(before: state, after: nil) == .unknown)
    }
}
