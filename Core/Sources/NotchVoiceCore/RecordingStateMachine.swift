import Foundation

/// Resolves raw key events from the modifier tap into recording effects.
///
/// Capture always starts on key-down, before the gesture is known — deciding
/// first would clip the first word. The gesture is resolved on key-up.
///
/// Hands-free is a **chord**: the binding key plus Space, held together. Chosen
/// over a double tap because it is unambiguous the instant it arrives — a double
/// tap can only be recognised by waiting out a window, which every short tap
/// then pays for whether or not a second one is coming.
///
/// Pure logic: no AppKit, no timers, no clock reads. The host supplies
/// timestamps and drives `.maxDurationReached` from its own timer, which is what
/// makes every branch testable.
public struct RecordingStateMachine: Sendable {

    public struct Thresholds: Sendable {
        /// Held at least this long counts as push-to-talk rather than a stray tap.
        public let hold: TimeInterval

        public init(hold: TimeInterval = 0.4) {
            self.hold = hold
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down; the gesture is not yet decided.
        case holding(downAt: TimeInterval)
        /// Hands-free. Capture continues until the key is tapped again.
        case locked
    }

    public enum Event: Equatable, Sendable {
        case keyDown(at: TimeInterval)
        case keyUp(at: TimeInterval)
        /// Space arrived while the binding key was held — the hands-free chord.
        case chordPressed
        /// Any other non-binding key was pressed.
        case otherKeyPressed
        case escapePressed
        case maxDurationReached
    }

    public enum Effect: Equatable, Sendable {
        case none
        case startCapture
        case enterLocked
        case stopAndTranscribe
        /// Throw the audio away. No transcription, no paste.
        case discard
    }

    public private(set) var state: State = .idle
    private let thresholds: Thresholds

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public mutating func handle(_ event: Event) -> Effect {
        switch (state, event) {

        // --- idle ------------------------------------------------------
        case let (.idle, .keyDown(t)):
            state = .holding(downAt: t)
            return .startCapture

        case (.idle, _):
            return .none

        // --- holding ---------------------------------------------------
        case let (.holding(downAt), .keyUp(t)):
            state = .idle
            // Too brief to be a deliberate push-to-talk. Previously this armed
            // the double-tap window; with the chord there is nothing to wait
            // for, so it resolves immediately instead of after 300ms.
            return t - downAt >= thresholds.hold ? .stopAndTranscribe : .discard

        case (.holding, .chordPressed):
            state = .locked
            return .enterLocked

        case (.holding, .otherKeyPressed), (.holding, .escapePressed):
            state = .idle
            return .discard

        case (.holding, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        // Auto-repeat while the key is held. The original `downAt` must
        // survive, or a long hold would keep resetting to a short one.
        case (.holding, .keyDown):
            return .none

        // --- locked ----------------------------------------------------
        case (.locked, .keyDown):
            state = .idle
            return .stopAndTranscribe

        case (.locked, .escapePressed):
            state = .idle
            return .discard

        case (.locked, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        // Typing while locked is expected — hands-free is deliberate. That
        // includes Space, which is why the chord does nothing a second time.
        case (.locked, .keyUp),
             (.locked, .chordPressed),
             (.locked, .otherKeyPressed):
            return .none
        }
    }
}
