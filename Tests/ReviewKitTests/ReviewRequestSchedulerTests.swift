import Foundation
import Testing

@testable import ReviewKit

/// Deterministic scheduler tests: sleep is injected and resolved manually so
/// no test depends on wall-clock time.
@MainActor
struct ReviewRequestSchedulerTests {
    /// Controllable sleep: each call suspends until `resume()` releases it.
    @MainActor
    final class ManualSleeper {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private(set) var sleepCount = 0

        func sleep(_: Duration) async {
            sleepCount += 1
            await withCheckedContinuation { continuations.append($0) }
        }

        func resume() {
            guard !continuations.isEmpty else { return }
            continuations.removeFirst().resume()
        }

        /// Lets the scheduled Task reach its next suspension point.
        func settle() async {
            for _ in 0..<20 { await Task.yield() }
        }
    }

    @Test func firesAfterInitialDelayWhenAllGatesPass() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(sleep: sleeper.sleep)
        var requested = false

        scheduler.scheduleIfPossible(
            shouldRequest: { !requested },
            isBlocked: { false },
            canRequestNow: { true },
            request: { requested = true }
        )
        await sleeper.settle()
        #expect(!requested)

        sleeper.resume()  // initial delay elapses
        await sleeper.settle()
        #expect(requested)
    }

    @Test func retriesWhileBlockedAndFiresOnceUnblocked() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(sleep: sleeper.sleep)
        var blocked = true
        var requested = false

        scheduler.scheduleIfPossible(
            shouldRequest: { !requested },
            isBlocked: { false },
            hasBlockingPresentation: { blocked },
            canRequestNow: { true },
            request: { requested = true }
        )
        await sleeper.settle()
        sleeper.resume()  // initial delay; attempt 0 hits the blocker
        await sleeper.settle()
        #expect(!requested)

        blocked = false
        sleeper.resume()  // retry interval elapses; attempt 1 fires
        await sleeper.settle()
        #expect(requested)
    }

    @Test func givesUpAfterMaxRetriesLeavingEligibilityIntact() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(
            configuration: .init(maxRetries: 2),
            sleep: sleeper.sleep
        )
        var stillPending = true
        var requested = false

        scheduler.scheduleIfPossible(
            shouldRequest: { stillPending },
            isBlocked: { true },  // schedule-time guard passes only if unblocked
            canRequestNow: { true },
            request: { requested = true }
        )
        // Blocked at schedule time: nothing scheduled at all.
        #expect(sleeper.sleepCount == 0)

        scheduler.scheduleIfPossible(
            shouldRequest: { stillPending },
            isBlocked: { false },
            hasBlockingPresentation: { true },
            canRequestNow: { true },
            request: { requested = true }
        )
        await sleeper.settle()
        // initial delay + retries: attempts 0,1,2 then give up.
        for _ in 0..<3 {
            sleeper.resume()
            await sleeper.settle()
        }
        #expect(!requested)
        #expect(stillPending)  // pending flag untouched — next trigger can retry
        stillPending = false
    }

    @Test func schedulingIsIdempotentWhileInFlight() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(sleep: sleeper.sleep)
        var requestCount = 0

        for _ in 0..<3 {
            scheduler.scheduleIfPossible(
                shouldRequest: { true },
                isBlocked: { false },
                canRequestNow: { true },
                request: { requestCount += 1 }
            )
        }
        await sleeper.settle()
        #expect(sleeper.sleepCount == 1)  // only one round in flight

        sleeper.resume()
        await sleeper.settle()
        #expect(requestCount == 1)
    }

    @Test func cancelStopsInFlightRoundAndAllowsRescheduling() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(sleep: sleeper.sleep)
        var requested = false

        scheduler.scheduleIfPossible(
            shouldRequest: { !requested },
            isBlocked: { false },
            canRequestNow: { true },
            request: { requested = true }
        )
        await sleeper.settle()
        scheduler.cancel()
        sleeper.resume()
        await sleeper.settle()
        #expect(!requested)

        scheduler.scheduleIfPossible(
            shouldRequest: { !requested },
            isBlocked: { false },
            canRequestNow: { true },
            request: { requested = true }
        )
        await sleeper.settle()
        sleeper.resume()
        await sleeper.settle()
        #expect(requested)
    }

    @Test func fireTimeGateReValidatesEvenWhenScheduleTimeGatePassed() async {
        let sleeper = ManualSleeper()
        let scheduler = ReviewRequestScheduler(
            configuration: .init(maxRetries: 0),
            sleep: sleeper.sleep
        )
        var canRequest = true
        var requested = false

        scheduler.scheduleIfPossible(
            shouldRequest: { true },
            isBlocked: { false },
            canRequestNow: { canRequest },
            request: { requested = true }
        )
        canRequest = false  // gate flips during the initial delay
        await sleeper.settle()
        sleeper.resume()
        await sleeper.settle()
        #expect(!requested)
    }
}
