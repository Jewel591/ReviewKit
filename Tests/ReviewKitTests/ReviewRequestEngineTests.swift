import Foundation
import Testing

@testable import ReviewKit

@MainActor
struct ReviewRequestEngineTests {
    private func makeEngine(
        store: InMemoryStore = InMemoryStore(),
        clock: MutableDateProvider = MutableDateProvider(),
        recorder: EventRecorder? = nil
    ) -> ReviewRequestEngine {
        ReviewRequestEngine(
            store: store,
            dateProvider: clock,
            onEvent: { recorder?.record($0) }
        )
    }

    // MARK: - #1030: no unified thresholds

    @Test func freshInstallCanAskAtTheFirstWinMoment() {
        // No install age, session count or event threshold: the app's own
        // choice of moment is the eligibility decision.
        let engine = makeEngine()

        #expect(engine.offer(source: "purchase"))
        #expect(engine.pendingOpportunity?.source == "purchase")
        #expect(engine.canRequestNow())
    }

    @Test func performRecordsOnlyWhenThePlatformCallHappened() {
        let store = InMemoryStore()
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine = makeEngine(store: store, clock: clock, recorder: recorder)
        engine.offer(source: "purchase")

        // Arbiter refused: nothing stamped, opportunity kept for a retry.
        #expect(!engine.performRequest { false })
        #expect(engine.pendingOpportunity != nil)
        #expect(store.date(forKey: "reviewKit_lastRequestDate") == nil)
        #expect(!recorder.events.contains(.requestRecorded(source: "purchase")))

        var calls = 0
        #expect(engine.performRequest {
            calls += 1
            return true
        })
        #expect(calls == 1)
        #expect(engine.pendingOpportunity == nil)
        #expect(store.date(forKey: "reviewKit_lastRequestDate") == clock.now)
        #expect(store.date(forKey: "reviewKit_lastRequestDate_purchase") == clock.now)
        #expect(recorder.events.last == .requestRecorded(source: "purchase"))

        // Consumed: the same opportunity cannot fire twice.
        #expect(!engine.performRequest { true })
    }

    // MARK: - Throttles

    @Test func minimumGapBlocksAnySourceFor14Days() {
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine = makeEngine(clock: clock, recorder: recorder)
        engine.offer(source: "record_milestone")
        engine.performRequest { true }

        clock.advance(days: 13)
        #expect(!engine.offer(source: "purchase"))
        #expect(recorder.blockedGates.last == .minimumGap)

        clock.advance(days: 1)
        #expect(engine.offer(source: "purchase"))
    }

    @Test func sameSourceWaits365DaysButOtherSourcesDoNot() {
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine = makeEngine(clock: clock, recorder: recorder)
        engine.offer(source: "record_milestone")
        engine.performRequest { true }

        clock.advance(days: 30)
        #expect(!engine.offer(source: "record_milestone"))
        #expect(recorder.blockedGates.last == .sourceCooldown)
        #expect(engine.offer(source: "purchase"))
        engine.performRequest { true }

        clock.advance(days: 335)  // 365 days after the first record_milestone
        #expect(engine.offer(source: "record_milestone"))
    }

    // MARK: - Opportunity lifecycle

    @Test func firstComeFirstServed() {
        let recorder = EventRecorder()
        let engine = makeEngine(recorder: recorder)

        #expect(engine.offer(source: "record_milestone"))
        #expect(!engine.offer(source: "purchase"))
        #expect(engine.pendingOpportunity?.source == "record_milestone")
        #expect(recorder.blockedGates.last == .pendingOpportunity)
    }

    @Test func expiresAtDeadlineEvenIfNeverScheduledAndWritesNoCooldown() {
        let store = InMemoryStore()
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine = makeEngine(store: store, clock: clock, recorder: recorder)
        engine.offer(source: "purchase")

        clock.advance(seconds: ReviewRequestPolicy.opportunityLifetime)
        #expect(!engine.canRequestNow())
        #expect(engine.pendingOpportunity == nil)
        #expect(recorder.events.last == .expired(source: "purchase"))
        #expect(store.date(forKey: "reviewKit_lastRequestDate") == nil)
        #expect(store.date(forKey: "reviewKit_lastRequestDate_purchase") == nil)

        // The source was not consumed: its next win moment can ask.
        #expect(engine.offer(source: "purchase"))
    }

    @Test func expiredOpportunityDoesNotBlockANewOffer() {
        let clock = MutableDateProvider()
        let engine = makeEngine(clock: clock)
        engine.offer(source: "record_milestone")

        clock.advance(seconds: ReviewRequestPolicy.opportunityLifetime + 1)
        #expect(engine.offer(source: "purchase"))
        #expect(engine.pendingOpportunity?.source == "purchase")
    }

    @Test func opportunityDoesNotSurviveRelaunch() {
        let store = InMemoryStore()
        let first = makeEngine(store: store)
        first.offer(source: "purchase")

        let relaunched = makeEngine(store: store)
        #expect(relaunched.pendingOpportunity == nil)
        #expect(!relaunched.canRequestNow())
    }

    // MARK: - Counters

    @Test func countingNeverOffersByItself() {
        let engine = makeEngine()
        engine.recordSignificantEvent("recordSaved", count: 50)

        #expect(engine.significantEventCount("recordSaved") == 50)
        #expect(engine.pendingOpportunity == nil)
    }
}
