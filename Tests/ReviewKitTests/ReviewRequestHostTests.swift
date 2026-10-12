import Foundation
import SwiftUI
import Testing

@testable import ReviewKit

/// The `.reviewRequestHost` decisions, driven without rendering SwiftUI.
@MainActor
struct ReviewRequestHostTests {
    @MainActor
    private struct Harness {
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine: ReviewRequestEngine
        let sleeper: ManualSleeper
        let driver: ReviewRequestHostDriver
        let calls = Counter()

        @MainActor
        init() {
            let recorder = recorder
            engine = ReviewRequestEngine(
                store: InMemoryStore(),
                dateProvider: clock,
                onEvent: { recorder.record($0) }
            )
            sleeper = ManualSleeper(clock: clock)
            driver = ReviewRequestHostDriver(
                scheduler: ReviewRequestScheduler(sleep: sleeper.sleep)
            )
        }

        func request(blocked: Bool, presenting: @escaping @MainActor () -> Bool = { false })
            -> ReviewRequestHostDriver.Request
        {
            let calls = calls
            return ReviewRequestHostDriver.Request(
                engine: engine,
                isBlocked: blocked,
                hasBlockingPresentation: presenting,
                perform: {
                    calls.value += 1
                    return true
                }
            )
        }

        func offer(_ source: ReviewRequestSource, blocked: Bool) {
            engine.offer(source: source)
            driver.opportunityChanged(engine.pendingOpportunity?.id, request: request(blocked: blocked))
        }
    }

    @MainActor
    final class Counter {
        var value = 0
    }

    @Test func nonActiveScenePhaseIsBlocked() {
        #expect(!ReviewRequestHostDriver.isBlocked(hostBlocked: false, scenePhase: .active))
        #expect(ReviewRequestHostDriver.isBlocked(hostBlocked: false, scenePhase: .inactive))
        #expect(ReviewRequestHostDriver.isBlocked(hostBlocked: false, scenePhase: .background))
        #expect(ReviewRequestHostDriver.isBlocked(hostBlocked: true, scenePhase: .active))
    }

    @Test func offerWhileUnblockedFiresAfterTheInitialDelay() async {
        let h = Harness()
        h.offer("purchase", blocked: false)
        await h.sleeper.settle()
        #expect(h.calls.value == 0)

        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(h.calls.value == 1)
        #expect(h.recorder.events.last == .requestRecorded(source: "purchase"))
    }

    @Test func offerWhileBlockedWaitsForTheBlockToClear() async {
        // e.g. the paywall sheet is still dismissing when the purchase succeeds.
        let h = Harness()
        h.offer("purchase", blocked: true)
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 0)

        h.driver.blockingChanged(request: h.request(blocked: false))
        await h.sleeper.settle()
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(h.calls.value == 1)
    }

    @Test func blockAppearingMidRoundCancelsThenReschedulesWhenCleared() async {
        // e.g. a success celebration starts right after the paywall closed.
        let h = Harness()
        h.offer("purchase", blocked: false)
        await h.sleeper.settle()

        h.driver.blockingChanged(request: h.request(blocked: true))
        h.sleeper.resume()  // the stale round's delay elapses
        await h.sleeper.settle()
        #expect(h.calls.value == 0)
        #expect(h.engine.pendingOpportunity != nil)

        h.driver.blockingChanged(request: h.request(blocked: false))
        await h.sleeper.settle()
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(h.calls.value == 1)
    }

    @Test func blockedPastTheDeadlineNeverRequests() async {
        let h = Harness()
        h.offer("purchase", blocked: true)
        let deadline = h.engine.pendingOpportunity!.deadline

        h.clock.now = deadline
        h.driver.blockingChanged(request: h.request(blocked: false))
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 0)
        #expect(h.calls.value == 0)
        #expect(h.engine.pendingOpportunity == nil)
        #expect(h.recorder.events.last == .expired(source: "purchase"))
    }

    @Test func unobservablePresentationIsCheckedAtFireTime() async {
        let h = Harness()
        var presenting = true
        h.engine.offer(source: "purchase")
        h.driver.opportunityChanged(
            h.engine.pendingOpportunity?.id,
            request: h.request(blocked: false, presenting: { presenting })
        )
        await h.sleeper.settle()
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(h.calls.value == 0)

        presenting = false
        h.sleeper.resume()  // retry interval
        await h.sleeper.settle()
        #expect(h.calls.value == 1)
    }

    @Test func clearedOpportunityDoesNotSchedule() async {
        let h = Harness()
        h.driver.opportunityChanged(nil, request: h.request(blocked: false))
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 0)
    }
}
