import Testing
@testable import NotchVoiceCore

@Suite("AXBudget")
struct AXBudgetTests {

    let budget = AXBudget(total: 0.25, perCallCap: 0.1, startingAt: 100)

    @Test("a fresh budget hands out the per-call cap")
    func freshBudgetIsCapped() {
        #expect(budget.timeout(at: 100) == Float(0.1))
    }

    @Test("near the deadline a call gets only what is left")
    func tailIsWhatRemains() throws {
        let timeout = try #require(budget.timeout(at: 100.2))
        #expect(abs(timeout - 0.05) < 0.0001)
    }

    @Test("a spent budget refuses further calls")
    func spentBudgetRefuses() {
        #expect(budget.timeout(at: 100.25) == nil)
        #expect(budget.timeout(at: 101) == nil)
    }

    @Test("a sliver below the floor is not worth a call")
    func sliverRefuses() {
        #expect(budget.timeout(at: 100.249) == nil)
    }

    @Test("several calls together never exceed the total")
    func callsShareOneDeadline() {
        // Each call is assumed to run its full timeout — the worst case the
        // budget exists to bound.
        var now: Double = 100
        var spent: Double = 0
        while let timeout = budget.timeout(at: now) {
            spent += Double(timeout)
            now += Double(timeout)
        }
        #expect(spent <= 0.25 + 0.0001)
    }
}
