import Foundation
import Testing

@testable import ReviewKit

/// Upgrading a shipped 0.x host (here: MONO's real predecessor key contract,
/// one undifferentiated action counter) to 1.0.
@MainActor
struct StorageKeyMigrationTests {
    private static let legacyKeys = ReviewPromptStorageKeys(
        significantEventTotal: "reviewPrompt_successfulActionCount",
        lastRequestDate: "reviewPrompt_lastReviewPromptDate",
        legacyPendingRequest: "reviewPrompt_pendingReviewRequest",
        significantEventKey: { _ in "reviewPrompt_successfulActionCount" },
        sourceLastRequestDateKey: { "reviewPrompt_lastRequestDate_\($0.rawValue)" }
    )

    /// State a 0.2.0 install leaves behind: counters, a pending flag that was
    /// never served, an old request date and fields 1.0 no longer uses.
    private static func legacyStore(lastRequestDaysAgo: Int, now: Date) -> InMemoryStore {
        let store = InMemoryStore()
        store.set(12, forKey: "reviewPrompt_appSessionCount")
        store.set(30, forKey: "reviewPrompt_successfulActionCount")
        store.set(now.addingTimeInterval(-400 * 86_400), forKey: "reviewPrompt_firstLaunchDate")
        store.set(
            now.addingTimeInterval(-Double(lastRequestDaysAgo) * 86_400),
            forKey: "reviewPrompt_lastReviewPromptDate"
        )
        store.set("2.3.0", forKey: "reviewPrompt_lastRequestVersion")
        store.set(true, forKey: "reviewPrompt_pendingReviewRequest")
        return store
    }

    @Test func upgradeNeverReplaysTheLegacyPendingRequest() {
        let clock = MutableDateProvider()
        let store = Self.legacyStore(lastRequestDaysAgo: 200, now: clock.now)

        let engine = ReviewRequestEngine(store: store, keys: Self.legacyKeys, dateProvider: clock)

        #expect(engine.pendingOpportunity == nil)
        #expect(!engine.canRequestNow())
        #expect(store.bool(forKey: "reviewPrompt_pendingReviewRequest") == false)
    }

    @Test func counterSurvivesAndKeepsCountingWithoutDoubleCounting() {
        let clock = MutableDateProvider()
        let store = Self.legacyStore(lastRequestDaysAgo: 200, now: clock.now)
        let engine = ReviewRequestEngine(store: store, keys: Self.legacyKeys, dateProvider: clock)

        #expect(engine.significantEventCount("recordSaved") == 30)
        engine.recordSignificantEvent("recordSaved")
        #expect(engine.significantEventCount("recordSaved") == 31)
        #expect(store.integer(forKey: "reviewPrompt_successfulActionCount") == 31)
    }

    @Test func legacyRequestDateStillHoldsTheMinimumGap() {
        let clock = MutableDateProvider()
        let store = Self.legacyStore(lastRequestDaysAgo: 3, now: clock.now)
        let engine = ReviewRequestEngine(store: store, keys: Self.legacyKeys, dateProvider: clock)

        #expect(!engine.offer(source: "record_milestone"))
        clock.advance(days: 11)
        #expect(engine.offer(source: "record_milestone"))
    }

    @Test func sourceHistoryStartsEmpty() {
        // The 0.x request had no source; it must not be attributed to one.
        let clock = MutableDateProvider()
        let store = Self.legacyStore(lastRequestDaysAgo: 20, now: clock.now)
        let engine = ReviewRequestEngine(store: store, keys: Self.legacyKeys, dateProvider: clock)

        #expect(engine.offer(source: "purchase"))
        #expect(store.date(forKey: "reviewPrompt_lastRequestDate_purchase") == nil)
    }

    /// Default keys are part of the upgrade contract for apps adopting 1.x
    /// fresh: renaming any of them resets counters and cooldowns.
    @Test func namespacedDefaultKeysAreStable() {
        let keys = ReviewPromptStorageKeys(namespace: "reviewPrompt")
        #expect(keys.significantEventTotal == "reviewPrompt_significantEventTotal")
        #expect(keys.lastRequestDate == "reviewPrompt_lastRequestDate")
        #expect(keys.legacyPendingRequest == "reviewPrompt_pendingRequest")
        #expect(keys.significantEventKey("recordSaved") == "reviewPrompt_significantEvent_recordSaved")
        #expect(keys.sourceLastRequestDateKey("purchase") == "reviewPrompt_lastRequestDate_purchase")
        #expect(ReviewPromptStorageKeys().lastRequestDate == "reviewKit_lastRequestDate")
    }
}
