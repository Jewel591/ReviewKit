import Foundation
import Testing

@testable import ReviewKit

/// Deterministic scheduler tests: sleep is injected and resolved manually, and
/// each resolved sleep advances the engine clock by the requested duration, so
/// no test depends on wall-clock time.
@MainActor
struct ReviewRequestSchedulerTests {
    private struct Harness {
        let clock = MutableDateProvider()
        let recorder = EventRecorder()
        let engine: ReviewRequestEngine
        let sleeper: ManualSleeper
        let scheduler: ReviewRequestScheduler

        @MainActor
        init() {
            let recorder = recorder
            engine = ReviewRequestEngine(
                store: InMemoryStore(),
                dateProvider: clock,
                onEvent: { recorder.record($0) }
            )
            sleeper = ManualSleeper(clock: clock)
            scheduler = ReviewRequestScheduler(sleep: sleeper.sleep)
        }
    }

    @Test func firesAfterInitialDelayWhenAllGatesPass() async {
        let h = Harness()
        var requested = 0
        h.engine.offer(source: "purchase")

        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) {
            requested += 1
            return true
        }
        await h.sleeper.settle()
        #expect(requested == 0)

        h.sleeper.resume()  // initial delay elapses
        await h.sleeper.settle()
        #expect(requested == 1)
        #expect(h.engine.pendingOpportunity == nil)
    }

    @Test func doesNothingWithoutAnOpportunity() async {
        let h = Harness()
        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) { true }
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 0)
    }

    @Test func retriesWhileBlockedAndFiresOnceUnblocked() async {
        let h = Harness()
        var presenting = true
        var requested = false
        h.engine.offer(source: "purchase")

        h.scheduler.scheduleIfPossible(
            engine: h.engine,
            isBlocked: { false },
            hasBlockingPresentation: { presenting }
        ) {
            requested = true
            return true
        }
        await h.sleeper.settle()
        h.sleeper.resume()  // initial delay; attempt hits the blocker
        await h.sleeper.settle()
        #expect(!requested)

        presenting = false
        h.sleeper.resume()  // retry interval elapses
        await h.sleeper.settle()
        #expect(requested)
    }

    @Test func refusedPerformRetriesUntilAccepted() async {
        let h = Harness()
        var arbiterAllows = false
        var calls = 0
        h.engine.offer(source: "purchase")

        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) {
            guard arbiterAllows else { return false }
            calls += 1
            return true
        }
        await h.sleeper.settle()
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(calls == 0)
        #expect(h.engine.pendingOpportunity != nil)

        arbiterAllows = true
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(calls == 1)
        #expect(h.recorder.events.last == .requestRecorded(source: "purchase"))
    }

    @Test func blockedRoundStopsAtTheDeadlineAndExpires() async {
        let h = Harness()
        var requested = false
        h.engine.offer(source: "purchase")

        h.scheduler.scheduleIfPossible(
            engine: h.engine,
            isBlocked: { false },
            hasBlockingPresentation: { true }
        ) {
            requested = true
            return true
        }
        await h.sleeper.settle()
        var rounds = 0
        while h.sleeper.hasPendingSleep, rounds < 100 {
            h.sleeper.resume()
            await h.sleeper.settle()
            rounds += 1
        }
        #expect(!requested)
        #expect(h.engine.pendingOpportunity == nil)
        #expect(h.recorder.events.last == .expired(source: "purchase"))
        // 1.5s + ten 10s retries + a final short sleep reaches the 180s deadline.
        #expect(rounds < 25)
    }

    @Test func cancelAndRescheduleDoesNotExtendTheDeadline() async {
        let h = Harness()
        var requested = false
        h.engine.offer(source: "purchase")
        let deadline = h.engine.pendingOpportunity!.deadline

        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) {
            requested = true
            return true
        }
        await h.sleeper.settle()
        h.scheduler.cancel()
        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(!requested)

        // Host stayed blocked past the deadline, then cleared.
        h.clock.now = deadline
        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) {
            requested = true
            return true
        }
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 1)  // nothing new was scheduled
        #expect(!requested)
        #expect(h.engine.pendingOpportunity == nil)
    }

    @Test func blockedAtScheduleTimeSchedulesNothing() async {
        let h = Harness()
        h.engine.offer(source: "purchase")

        h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { true }) { true }
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 0)
        #expect(h.engine.pendingOpportunity != nil)
    }

    @Test func schedulingIsIdempotentWhileInFlight() async {
        let h = Harness()
        var requestCount = 0
        h.engine.offer(source: "purchase")

        for _ in 0..<3 {
            h.scheduler.scheduleIfPossible(engine: h.engine, isBlocked: { false }) {
                requestCount += 1
                return true
            }
        }
        await h.sleeper.settle()
        #expect(h.sleeper.sleepCount == 1)

        h.sleeper.resume()
        await h.sleeper.settle()
        #expect(requestCount == 1)
    }
}
