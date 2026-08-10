import Foundation

/// Resolves raw key events from the modifier tap into recording effects.
///
/// Capture always starts on key-down, before the gesture is known — deciding
/// first would clip the first word. The gesture is resolved on key-up, and a
/// short tap keeps capturing while it waits to find out whether a second tap
/// is coming.
///
/// Pure logic: no AppKit, no timers, no clock reads. The host supplies
/// timestamps and drives `.doubleTapWindowExpired` and `.maxDurationReached`
/// from its own timers, which is what makes every branch testable.
public struct RecordingStateMachine: Sendable {

    public struct Thresholds: Sendable {
        /// Held at least this long counts as push-to-talk rather than a tap.
        public let hold: TimeInterval
        /// A second tap within this window of the first release locks.
        public let doubleTap: TimeInterval

        public init(hold: TimeInterval = 0.4, doubleTap: TimeInterval = 0.3) {
            self.hold = hold
            self.doubleTap = doubleTap
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Key is down; the gesture is not yet decided.
        case holding(downAt: TimeInterval)
        /// Key was tapped and released quickly. Still capturing while we wait
        /// to see whether a second tap arrives.
        case awaitingSecondTap(firstUpAt: TimeInterval)
        /// Hands-free. Capture continues until the key is tapped again.
        case locked
    }

    public enum Event: Equatable, Sendable {
        case keyDown(at: TimeInterval)
        case keyUp(at: TimeInterval)
        /// Any non-binding key was pressed. Makes `⌥ + o` still type `ø`.
        case otherKeyPressed
        case escapePressed
        case doubleTapWindowExpired
        case maxDurationReached
    }

    public enum Effect: Equatable, Sendable {
        case none
        case startCapture
        /// Keep capturing, and schedule `.doubleTapWindowExpired`.
        case armDoubleTapTimer
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
            if t - downAt >= thresholds.hold {
                state = .idle
                return .stopAndTranscribe
            }
            state = .awaitingSecondTap(firstUpAt: t)
            return .armDoubleTapTimer

        case (.holding, .otherKeyPressed), (.holding, .escapePressed):
            state = .idle
            return .discard

        case (.holding, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        case (.holding, .keyDown), (.holding, .doubleTapWindowExpired):
            return .none

        // --- awaitingSecondTap -----------------------------------------
        case let (.awaitingSecondTap(firstUpAt), .keyDown(t)):
            if t - firstUpAt <= thresholds.doubleTap {
                state = .locked
                return .enterLocked
            }
            // Too late to be a double tap. The first tap's audio is stale,
            // so this is a fresh hold rather than a continuation.
            state = .holding(downAt: t)
            return .startCapture

        case (.awaitingSecondTap, .doubleTapWindowExpired),
             (.awaitingSecondTap, .otherKeyPressed),
             (.awaitingSecondTap, .escapePressed):
            state = .idle
            return .discard

        case (.awaitingSecondTap, .maxDurationReached):
            state = .idle
            return .stopAndTranscribe

        case (.awaitingSecondTap, .keyUp):
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

        // Typing while locked is expected — hands-free is deliberate.
        case (.locked, .keyUp),
             (.locked, .otherKeyPressed),
             (.locked, .doubleTapWindowExpired):
            return .none
        }
    }
}
