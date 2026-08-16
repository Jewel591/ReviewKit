import Foundation

/// Timing layer: decides *when to actually fire* a request the engine has
/// already deemed eligible.
///
/// Why this exists: `requestReview()` should land in a quiet moment right
/// after the app's success UI, but the moment eligibility is established the
/// screen may be busy — transition animations, a local overlay the view layer
/// cannot observe, an inactive scene. The scheduler applies an initial delay,
/// re-checks every gate at fire time, and retries a bounded number of times
/// while blocked. If retries run out, the eligibility (pending flag) is left
/// intact for the next trigger point.
///
/// All gates are injected closures, re-evaluated live on every attempt.
///
/// Caveat for SwiftUI hosts: closures capture the caller's values at schedule
/// time (views are value types; `@Environment` values in a captured closure do
/// not track later updates). When an *observable* blocking state appears,
/// `cancel()` the in-flight schedule and re-schedule with fresh closures once
/// it clears — otherwise a long retry loop can fire against stale state and
/// burn the cooldown while the app is not even active.
@MainActor
public final class ReviewRequestScheduler {
    public struct Configuration: Sendable {
        /// Delay between eligibility and the first attempt, letting success
        /// UI/transitions settle so the prompt does not stomp on them.
        public var initialDelay: Duration
        /// Interval between retries while blocked.
        public var retryInterval: Duration
        /// Maximum retries (excluding the first attempt). When exhausted the
        /// round is abandoned; eligibility persists for the next trigger.
        public var maxRetries: Int

        public init(
            initialDelay: Duration = .seconds(1.5),
            retryInterval: Duration = .seconds(10),
            maxRetries: Int = 18
        ) {
            self.initialDelay = initialDelay
            self.retryInterval = retryInterval
            self.maxRetries = maxRetries
        }
    }

    private let configuration: Configuration
    private let sleep: @MainActor (Duration) async -> Void
    private var inFlightTask: Task<Void, Never>?
    private var generation = 0

    public init(
        configuration: Configuration = Configuration(),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.configuration = configuration
        self.sleep = sleep
    }

    /// Schedules one request attempt round. Idempotent while a non-cancelled
    /// round is in flight.
    ///
    /// - Parameters:
    ///   - shouldRequest: pending-eligibility flag (must turn false once
    ///     consumed or invalidated).
    ///   - isBlocked: observable blocking state (scene inactive, screen
    ///     locked, coordinator-managed overlay up...).
    ///   - hasBlockingPresentation: fallback detection for presentation state
    ///     the observable layer cannot see (e.g. UIKit presentation chain).
    ///   - canRequestNow: time-gate revalidation — wire to
    ///     `ReviewRequestEngine.canRequestNow()`.
    ///   - request: executed once all gates pass; the host calls the platform
    ///     `requestReview()` here and then `engine.recordRequested()`.
    public func scheduleIfPossible(
        shouldRequest: @escaping @MainActor () -> Bool,
        isBlocked: @escaping @MainActor () -> Bool,
        hasBlockingPresentation: @escaping @MainActor () -> Bool = { false },
        canRequestNow: @escaping @MainActor () -> Bool,
        request: @escaping @MainActor () -> Void
    ) {
        guard shouldRequest(), !isBlocked() else { return }
        if let task = inFlightTask, !task.isCancelled { return }

        generation += 1
        let scheduledGeneration = generation

        inFlightTask = Task { @MainActor in
            // After a cancel, a newer schedule may already own inFlightTask;
            // only clear our own generation.
            defer {
                if generation == scheduledGeneration {
                    inFlightTask = nil
                }
            }

            await sleep(configuration.initialDelay)

            // Negative values would make the ClosedRange below trap; treat
            // them as "no retries" instead of crashing at a distance from
            // where the configuration was built.
            let maxRetries = max(0, configuration.maxRetries)

            for attempt in 0...maxRetries {
                guard !Task.isCancelled, shouldRequest() else { return }

                if !isBlocked(), !hasBlockingPresentation(), canRequestNow() {
                    request()
                    return
                }

                guard attempt < maxRetries else { return }
                await sleep(configuration.retryInterval)
            }
        }
    }

    /// Cancels the in-flight round. Call when an observable blocking state
    /// appears; re-schedule with fresh closures once it clears.
    public func cancel() {
        inFlightTask?.cancel()
    }
}
