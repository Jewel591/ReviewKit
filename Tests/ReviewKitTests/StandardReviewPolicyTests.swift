import Foundation
import Testing

@testable import ReviewKit

@MainActor
struct StandardReviewPolicyTests {
    @Test func standardPolicyBecomesEligibleExactlyWhenAllGatesPass() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let engine = ReviewRequestEngine(
            conditions: StandardReviewPolicy.conditions(coreEvent: "win"),
            store: store,
            currentVersion: "1.0.0",
            dateProvider: dateProvider
        )

        // Enough events and sessions, but installed today.
        for _ in 0..<5 { engine.recordSession() }
        engine.recordSignificantEvent("win", count: 10)
        #expect(!engine.isEligible)

        // Crossing the install-age gate alone completes eligibility.
        dateProvider.advance(days: 7)
        engine.evaluateEligibility()
        #expect(engine.isEligible)
    }

    @Test func standardPolicyEnforcesCooldownAndVersionGateAfterRequest() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let conditions = StandardReviewPolicy.conditions(coreEvent: "win")
        let engine = ReviewRequestEngine(
            conditions: conditions,
            store: store,
            currentVersion: "1.0.0",
            dateProvider: dateProvider
        )
        for _ in 0..<5 { engine.recordSession() }
        engine.recordSignificantEvent("win", count: 10)
        dateProvider.advance(days: 7)
        engine.evaluateEligibility()
        engine.recordRequested()

        // Same version + inside cooldown: blocked on both axes.
        dateProvider.advance(days: 120)
        engine.evaluateEligibility()
        #expect(!engine.isEligible)

        // New version after cooldown: eligible again.
        let upgraded = ReviewRequestEngine(
            conditions: StandardReviewPolicy.conditions(coreEvent: "win"),
            store: store,
            currentVersion: "1.1.0",
            dateProvider: dateProvider
        )
        upgraded.evaluateEligibility()
        #expect(upgraded.isEligible)
    }

    @Test func suppressorsAppendAfterStandardGates() {
        var suppressed = true
        let conditions = StandardReviewPolicy.conditions(
            coreEvent: "win",
            suppressors: [
                CustomReviewCondition(identifier: "notSuppressed") { _ in !suppressed }
            ]
        )
        #expect(conditions.count == 6)
        #expect(conditions.last?.identifier == "notSuppressed")

        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let engine = ReviewRequestEngine(
            conditions: conditions,
            store: store,
            currentVersion: "1.0.0",
            dateProvider: dateProvider
        )
        for _ in 0..<5 { engine.recordSession() }
        engine.recordSignificantEvent("win", count: 10)
        dateProvider.advance(days: 7)
        engine.evaluateEligibility()
        #expect(!engine.isEligible)

        suppressed = false
        engine.evaluateEligibility()
        #expect(engine.isEligible)
    }
}
