import Foundation

/// Timing layer: serves the engine's pending opportunity at a quiet moment
/// before its deadline.
///
/// Why this exists: the win moment is usually followed by success UI — a
/// sheet dismissing, a celebration overlay, a transition. The scheduler
/// applies an initial delay, re-checks every gate at fire time, and retries
/// while blocked, but never past the opportunity's deadline. Cancelling and
/// re-scheduling never extends that deadline.
///
/// SwiftUI hosts should use
/// ``SwiftUICore/View/reviewRequestHost(engine:isBlocked:hasBlockingPresentation:perform:)``,
/// which owns a scheduler and the cancel/re-schedule wiring. Use this type
/// directly only from UIKit hosts.
///
/// Closures capture the caller's values at schedule time. When an observable
/// blocking state appears, `cancel()` and re-schedule with fresh closures once
/// it clears, so a retry never fires against stale state.
@MainActor
public final class ReviewRequestScheduler {
    public struct Configuration: Sendable {
        /// Delay between the offer and the first attempt, letting success
        /// UI/transitions settle so the prompt does not stomp on them.
        public var initialDelay: Duration
        /// Interval between retries while blocked.
        public var retryInterval: Duration

        public init(
            initialDelay: Duration = .seconds(1.5),
            retryInterval: Duration = .seconds(10)
        ) {
            self.initialDelay = initialDelay
            self.retryInterval = retryInterval
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

    /// Schedules one attempt round for the engine's pending opportunity.
    /// Idempotent while a non-cancelled round is in flight.
    ///
    /// - Parameters:
    ///   - engine: owns the opportunity, its deadline and every gate.
    ///   - isBlocked: observable blocking state (scene inactive, screen
    ///     locked, app-owned overlay up...).
    ///   - hasBlockingPresentation: fallback detection for presentation state
    ///     the observable layer cannot see (e.g. UIKit presentation chain).
    ///   - perform: calls the platform `requestReview()` synchronously and
    ///     returns `true`, or returns `false` without calling it. See
    ///     ``ReviewRequestEngine/performRequest(_:)``.
    public func scheduleIfPossible(
        engine: ReviewRequestEngine,
        isBlocked: @escaping @MainActor () -> Bool,
        hasBlockingPresentation: @escaping @MainActor () -> Bool = { false },
        perform: @escaping @MainActor () -> Bool
    ) {
        guard engine.livePendingOpportunity() != nil, !isBlocked() else { return }
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

            while !Task.isCancelled {
                guard let opportunity = engine.livePendingOpportunity() else { return }

                if !isBlocked(), !hasBlockingPresentation(),
                    engine.performRequest(perform)
                {
                    return
                }

                let remaining = opportunity.deadline.timeIntervalSince(engine.now)
                guard remaining > 0 else {
                    engine.livePendingOpportunity()  // drops it and emits .expired
                    return
                }
                await sleep(min(configuration.retryInterval, .seconds(remaining)))
            }
        }
    }

    /// Cancels the in-flight round. Call when an observable blocking state
    /// appears; re-schedule with fresh closures once it clears.
    public func cancel() {
        inFlightTask?.cancel()
    }
}
