import Foundation
import Testing

@testable import ReviewKit

/// Verifies that a host migrating from an in-house implementation can map the
/// kit onto its historical persistence keys so shipped users keep their
/// counters and cooldowns. The key set below mirrors a real predecessor
/// contract (single significant-event counter, legacy key names).
@MainActor
struct StorageKeyMigrationTests {
    private static let legacyKeys = ReviewPromptStorageKeys(
        sessionCount: "reviewPrompt_appSessionCount",
        significantEventTotal: "reviewPrompt_successfulActionCount",
        firstLaunchDate: "reviewPrompt_firstLaunchDate",
        lastRequestDate: "reviewPrompt_lastReviewPromptDate",
        lastRequestVersion: "reviewPrompt_lastRequestVersion",
        pendingRequest: "reviewPrompt_pendingReviewRequest",
        // Predecessor had one undifferentiated action counter: every named
        // event maps onto the same legacy key (which is also the total).
        significantEventKey: { _ in "reviewPrompt_successfulActionCount" }
    )

    @Test func legacyCountersAndCooldownSurviveMigration() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()

        // State written by the predecessor implementation.
        store.set(12, forKey: "reviewPrompt_appSessionCount")
        store.set(30, forKey: "reviewPrompt_successfulActionCount")
        store.set(dateProvider.now.addingTimeInterval(-40 * 86_400), forKey: "reviewPrompt_firstLaunchDate")
        store.set(dateProvider.now.addingTimeInterval(-10 * 86_400), forKey: "reviewPrompt_lastReviewPromptDate")

        let engine = ReviewRequestEngine(
            conditions: [
                MinimumSessionsCondition(sessions: 5),
                MinimumSignificantEventsCondition(count: 20),
                MinimumDaysSinceInstallCondition(days: 7),
                CooldownCondition(days: 120),
            ],
            store: store,
            keys: Self.legacyKeys,
            currentVersion: "27.0.0",
            dateProvider: dateProvider
        )

        // Counters and install date carried over; only the cooldown blocks.
        engine.recordSession()
        #expect(!engine.isEligible)
        #expect(store.integer(forKey: "reviewPrompt_appSessionCount") == 13)

        dateProvider.advance(days: 111)  // 121 days since last prompt
        engine.recordSession()
        #expect(engine.isEligible)
    }

    @Test func pendingFlagFromPredecessorIsHonored() {
        let store = InMemoryStore()
        store.set(true, forKey: "reviewPrompt_pendingReviewRequest")

        let engine = ReviewRequestEngine(
            conditions: [],
            store: store,
            keys: Self.legacyKeys,
            currentVersion: "27.0.0"
        )
        #expect(engine.isEligible)
    }

    @Test func singleCounterMappingAggregatesAllNamedEvents() {
        let store = InMemoryStore()
        let engine = ReviewRequestEngine(
            conditions: [MinimumSignificantEventsCondition(count: 3)],
            store: store,
            keys: Self.legacyKeys,
            currentVersion: "27.0.0"
        )

        engine.recordSignificantEvent("manualRecord")
        engine.recordSignificantEvent("aiRecord", count: 2)

        // Both event names land in the same legacy counter, which is also the
        // total key. The engine must not double-count in that mapping.
        #expect(store.integer(forKey: "reviewPrompt_successfulActionCount") == 3)
    }
}
