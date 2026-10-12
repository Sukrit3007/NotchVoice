import Foundation

/// One time allowance shared by every Accessibility call in a single read.
///
/// Each AX call is synchronous IPC into another process, bounded by its own
/// messaging timeout. A flat per-call timeout lets the worst cases stack: three
/// calls at a quarter second each is three quarters of a second spent on an app
/// that is not answering. A budget bounds the whole read instead, and the
/// per-call cap stops the first slow call from spending all of it.
///
/// Pure: the host supplies the clock.
public struct AXBudget: Sendable {

    /// Below this, a call is not worth starting — it would time out before the
    /// other process could answer.
    public static let floor: TimeInterval = 0.002

    public let deadline: TimeInterval
    public let perCallCap: TimeInterval

    public init(total: TimeInterval, perCallCap: TimeInterval, startingAt now: TimeInterval) {
        self.deadline = now + total
        self.perCallCap = perCallCap
    }

    /// The messaging timeout for a call starting now, or nil once the budget is
    /// spent. `Float` because that is what `AXUIElementSetMessagingTimeout` takes.
    public func timeout(at now: TimeInterval) -> Float? {
        let remaining = deadline - now
        guard remaining >= Self.floor else { return nil }
        return Float(min(remaining, perCallCap))
    }
}
