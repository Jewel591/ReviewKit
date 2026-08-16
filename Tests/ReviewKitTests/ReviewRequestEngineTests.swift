import Foundation
import Testing

@testable import ReviewKit

@MainActor
struct ReviewRequestEngineTests {
    private func makeEngine(
        conditions: [any ReviewRequestCondition],
        store: InMemoryStore = InMemoryStore(),
        dateProvider: MutableDateProvider = MutableDateProvider(),
        version: String = "1.0.0",
        recorder: EventRecorder? = nil
    ) -> ReviewRequestEngine {
        ReviewRequestEngine(
            conditions: conditions,
            store: store,
            currentVersion: version,
            dateProvider: dateProvider,
            onEvent: { [weak recorder] in recorder?.record($0) }
        )
    }

    @Test func becomesEligibleWhenAllConditionsPass() {
        let recorder = EventRecorder()
        let engine = makeEngine(
            conditions: [
                MinimumSessionsCondition(sessions: 2),
                MinimumSignificantEventsCondition(count: 3),
            ],
            recorder: recorder
        )

        engine.recordSession()
        engine.recordSignificantEvent("save", count: 3)
        #expect(!engine.isEligible)

        engine.recordSession()
        #expect(engine.isEligible)
        #expect(recorder.events.contains(.becameEligible))
    }

    @Test func blockedEventNamesFirstFailingCondition() {
        let recorder = EventRecorder()
        let engine = makeEngine(
            conditions: [
                MinimumSessionsCondition(sessions: 1),
                MinimumSignificantEventsCondition(count: 5),
            ],
            recorder: recorder
        )

        engine.recordSession()
        #expect(recorder.blockedConditionIDs == ["minimumSignificantEvents"])
    }

    @Test func pendingEligibilityPersistsAcrossRelaunch() {
        let store = InMemoryStore()
        let engine = makeEngine(conditions: [MinimumSessionsCondition(sessions: 1)], store: store)
        engine.recordSession()
        #expect(engine.isEligible)

        // Simulated relaunch: a fresh engine over the same store.
        let relaunched = makeEngine(
            conditions: [MinimumSessionsCondition(sessions: 1)], store: store)
        #expect(relaunched.isEligible)
    }

    @Test func recordRequestedConsumesEligibilityAndStampsAnchors() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let recorder = EventRecorder()
        let engine = makeEngine(
            conditions: [MinimumSessionsCondition(sessions: 1)],
            store: store,
            dateProvider: dateProvider,
            version: "2.3.0",
            recorder: recorder
        )
        engine.recordSession()
        engine.recordRequested()

        #expect(!engine.isEligible)
        #expect(recorder.events.contains(.requestRecorded))

        let keys = ReviewPromptStorageKeys()
        #expect(store.date(forKey: keys.lastRequestDate) == dateProvider.now)
        #expect(store.string(forKey: keys.lastRequestVersion) == "2.3.0")
    }

    @Test func cooldownBlocksReEligibilityUntilElapsed() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let conditions: [any ReviewRequestCondition] = [
            MinimumSessionsCondition(sessions: 1),
            CooldownCondition(days: 120),
        ]
        let engine = makeEngine(conditions: conditions, store: store, dateProvider: dateProvider)
        engine.recordSession()
        engine.recordRequested()

        engine.recordSession()
        #expect(!engine.isEligible)

        dateProvider.advance(days: 120)
        engine.recordSession()
        #expect(engine.isEligible)
    }

    @Test func canRequestNowRevalidatesTimeGatesAgainstFreshContext() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        var quietEventDate: Date?
        let conditions: [any ReviewRequestCondition] = [
            MinimumSessionsCondition(sessions: 1),
            QuietPeriodCondition(
                identifier: "quietPeriod(marketing)",
                quietInterval: 3_600,
                lastEventDate: { quietEventDate }
            ),
        ]
        let engine = makeEngine(conditions: conditions, store: store, dateProvider: dateProvider)
        engine.recordSession()
        #expect(engine.isEligible)
        #expect(engine.canRequestNow())

        // A marketing prompt appears between eligibility and firing.
        quietEventDate = dateProvider.now
        #expect(!engine.canRequestNow())

        dateProvider.advance(seconds: 3_600)
        #expect(engine.canRequestNow())
    }

    @Test func canRequestNowIsFalseWithoutEstablishedEligibility() {
        // canRequestNow is a revalidation, not an independent decision: it
        // must never approve a request eligibility hasn't approved first.
        let engine = makeEngine(conditions: [MinimumSessionsCondition(sessions: 99)])
        #expect(!engine.canRequestNow())
    }

    @Test func canRequestNowSkipsMonotonicConditionsOnceEligible() {
        let store = InMemoryStore()
        let engine = makeEngine(
            conditions: [MinimumSessionsCondition(sessions: 1)], store: store)
        engine.recordSession()
        #expect(engine.isEligible)
        // Monotonic gates are not re-run at request time; with no
        // revalidating conditions configured, the check passes outright.
        #expect(engine.canRequestNow())
    }

    @Test func versionGateBlocksSecondAttemptInSameVersionOnly() {
        let store = InMemoryStore()
        let conditions: [any ReviewRequestCondition] = [
            MinimumSessionsCondition(sessions: 1),
            NotRequestedForCurrentVersionCondition(),
        ]
        let engine = makeEngine(conditions: conditions, store: store, version: "1.0.0")
        engine.recordSession()
        engine.recordRequested()

        engine.recordSession()
        #expect(!engine.isEligible)
        #expect(!engine.canRequestNow())

        // Same store, next app version.
        let upgraded = makeEngine(conditions: conditions, store: store, version: "1.1.0")
        upgraded.recordSession()
        #expect(upgraded.isEligible)
        #expect(upgraded.canRequestNow())
    }

    @Test func firstLaunchDateIsStampedOnceOnFirstInit() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        _ = makeEngine(
            conditions: [], store: store, dateProvider: dateProvider)
        let keys = ReviewPromptStorageKeys()
        let stamped = store.date(forKey: keys.firstLaunchDate)
        #expect(stamped == dateProvider.now)

        dateProvider.advance(days: 5)
        _ = makeEngine(conditions: [], store: store, dateProvider: dateProvider)
        #expect(store.date(forKey: keys.firstLaunchDate) == stamped)
    }

    @Test func minimumDaysSinceInstallGate() {
        let store = InMemoryStore()
        let dateProvider = MutableDateProvider()
        let conditions: [any ReviewRequestCondition] = [
            MinimumSessionsCondition(sessions: 1),
            MinimumDaysSinceInstallCondition(days: 7),
        ]
        let engine = makeEngine(conditions: conditions, store: store, dateProvider: dateProvider)
        engine.recordSession()
        #expect(!engine.isEligible)

        dateProvider.advance(days: 7)
        engine.recordSession()
        #expect(engine.isEligible)
    }

    @Test func namedEventCountersAreIndependentAndTotalAccumulates() {
        let recorder = EventRecorder()
        let engine = makeEngine(
            conditions: [
                MinimumSignificantEventsCondition(count: 2, event: "export"),
                MinimumSignificantEventsCondition(count: 3),
            ],
            recorder: recorder
        )

        engine.recordSignificantEvent("save", count: 3)
        // Total satisfied, named "export" counter still 0.
        #expect(!engine.isEligible)
        #expect(recorder.blockedConditionIDs.contains("minimumSignificantEvents(export)"))

        engine.recordSignificantEvent("export", count: 2)
        #expect(engine.isEligible)
    }

    @Test func customConditionActsAsHostSuppressor() {
        var paywallVisible = true
        let engine = makeEngine(
            conditions: [
                CustomReviewCondition(identifier: "paywallNotVisible") { _ in !paywallVisible }
            ]
        )
        engine.recordSession()
        #expect(!engine.isEligible)

        paywallVisible = false
        engine.recordSession()
        #expect(engine.isEligible)
    }
}
