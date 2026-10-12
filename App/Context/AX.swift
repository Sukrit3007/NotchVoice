import ApplicationServices
import NotchVoiceCore

/// Budgeted Accessibility calls, for everything that talks to another app's UI.
///
/// Each call sets the element's messaging timeout from an `AXBudget` before it
/// goes out, so no caller can forget to bound IPC into a process that may not
/// be answering, and a spent budget returns nil without making the call.
///
/// Not main-actor isolated: the AX API can be called from any thread, and the
/// read at the start of a dictation runs off the main thread so a slow app
/// cannot hold anything up.
enum AX {

    static func budget(total: TimeInterval, perCallCap: TimeInterval) -> AXBudget {
        AXBudget(total: total, perCallCap: perCallCap, startingAt: now)
    }

    static func element(
        _ attribute: String, of element: AXUIElement, within budget: AXBudget
    ) -> AXUIElement? {
        guard let value = copy(attribute, of: element, within: budget) else { return nil }
        // `CFGetTypeID` rather than a conditional cast: the attribute is typed
        // `CFTypeRef` and an `as?` to `AXUIElement` succeeds for values that are
        // not one.
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(
        _ attribute: String, of element: AXUIElement, within budget: AXBudget
    ) -> String? {
        copy(attribute, of: element, within: budget) as? String
    }

    static func int(
        _ attribute: String, of element: AXUIElement, within budget: AXBudget
    ) -> Int? {
        copy(attribute, of: element, within: budget) as? Int
    }

    static func range(
        _ attribute: String, of element: AXUIElement, within budget: AXBudget
    ) -> CFRange? {
        guard let value = copy(attribute, of: element, within: budget),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    static func perform(
        _ action: String, on element: AXUIElement, within budget: AXBudget
    ) -> Bool {
        guard arm(element, within: budget) else { return false }
        return AXUIElementPerformAction(element, action as CFString) == .success
    }

    @discardableResult
    static func set(
        _ attribute: String, to value: Bool, of element: AXUIElement, within budget: AXBudget
    ) -> Bool {
        guard arm(element, within: budget) else { return false }
        return AXUIElementSetAttributeValue(
            element, attribute as CFString, value as CFBoolean) == .success
    }

    @discardableResult
    static func set(
        _ attribute: String, to range: CFRange, of element: AXUIElement, within budget: AXBudget
    ) -> Bool {
        guard arm(element, within: budget) else { return false }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success
    }

    private static func copy(
        _ attribute: String, of element: AXUIElement, within budget: AXBudget
    ) -> CFTypeRef? {
        guard arm(element, within: budget) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// Sets the element's timeout from the budget, or says the budget is spent.
    ///
    /// Setting the timeout on the system-wide element sets it for the whole
    /// process; on any other element it applies to that element alone. Either
    /// way it is set again before every call, so nothing inherits a stale one.
    private static func arm(_ element: AXUIElement, within budget: AXBudget) -> Bool {
        guard let timeout = budget.timeout(at: now) else { return false }
        AXUIElementSetMessagingTimeout(element, timeout)
        return true
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// An `AXUIElement` that can be handed from the thread that found it to the one
/// that uses it.
///
/// `@unchecked` because Swift cannot vouch for a CF type. It is an immutable
/// reference to an element in another process, and each one here is passed
/// along once — found off the main thread at key-down, used on it at delivery —
/// never used from two threads at the same time.
struct AXElement: @unchecked Sendable {
    let raw: AXUIElement
}
