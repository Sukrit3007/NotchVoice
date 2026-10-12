/// Whether a paste visibly changed the field it was aimed at.
///
/// The paste promise proves some process *read* the clipboard — usually the
/// target — not that text arrived. This compares the field's length and
/// selection before and after. Pasting any text moves at least one of them:
/// an insertion grows the length and moves the caret, and replacing a selection
/// with text of the same length still collapses the selection. Content is never
/// compared, so nothing is read from the field but three numbers.
///
/// Pure: the host reads the fields over Accessibility and decides how long to
/// keep looking.
public enum PasteLanding {

    public struct FieldState: Equatable, Sendable {
        public let characterCount: Int
        public let selectionLocation: Int
        public let selectionLength: Int

        public init(characterCount: Int, selectionLocation: Int, selectionLength: Int) {
            self.characterCount = characterCount
            self.selectionLocation = selectionLocation
            self.selectionLength = selectionLength
        }
    }

    public enum Verdict: Equatable, Sendable {
        case landed
        case notLanded
        /// One side could not be read. Not evidence either way, so the caller
        /// falls back to trusting the promise.
        case unknown
    }

    public static func verdict(before: FieldState?, after: FieldState?) -> Verdict {
        guard let before, let after else { return .unknown }
        return before == after ? .notLanded : .landed
    }
}
