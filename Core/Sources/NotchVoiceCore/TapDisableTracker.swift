import Foundation

/// Decides when an event tap that keeps being switched off should be rebuilt
/// rather than switched back on yet again.
///
/// macOS disables a tap that is slow in its callback, and can disable one on
/// user input. Re-enabling handles the odd case; a tap disabled over and over
/// is in a state re-enabling does not fix, and a fresh one is cheap.
///
/// Disables shortly after wake are expected — the machine is sluggish while it
/// comes back — so they are re-enabled but not counted.
///
/// Pure: the host supplies timestamps.
public struct TapDisableTracker: Sendable {

    public let threshold: Int
    public let window: TimeInterval
    public let wakeGrace: TimeInterval

    private var recent: [TimeInterval] = []
    private var wokeAt: TimeInterval?

    public init(threshold: Int = 3, window: TimeInterval = 10, wakeGrace: TimeInterval = 10) {
        self.threshold = threshold
        self.window = window
        self.wakeGrace = wakeGrace
    }

    public mutating func noteWake(at now: TimeInterval) {
        wokeAt = now
        recent.removeAll()
    }

    /// Records one disable. Returns true when the tap should be rebuilt, and
    /// starts counting afresh so one rebuild does not trigger the next.
    public mutating func noteDisable(at now: TimeInterval) -> Bool {
        if let wokeAt, now - wokeAt < wakeGrace { return false }
        recent.removeAll { now - $0 > window }
        recent.append(now)
        guard recent.count >= threshold else { return false }
        recent.removeAll()
        return true
    }
}
