import Foundation

/// Analytics/diagnostics hook. ReviewKit emits these; the host forwards them
/// to its own logging or analytics pipeline.
public enum ReviewKitEvent: Sendable, Equatable {
    /// A win moment offered an opportunity and it passed every gate.
    case offered(source: ReviewRequestSource)
    /// An offer or a request-time check stopped at this gate.
    case blocked(source: ReviewRequestSource, gate: ReviewRequestGate, reason: String)
    /// The opportunity reached its deadline without being served. No
    /// cooldown was written.
    case expired(source: ReviewRequestSource)
    /// The host's perform closure reported that it called the platform
    /// `requestReview()`. Cooldowns were stamped. This is an *attempt*: the
    /// system may have shown nothing, and the app cannot know.
    case requestRecorded(source: ReviewRequestSource)
}

/// The engine's own gates, reported by ``ReviewKitEvent/blocked(source:gate:reason:)``.
public enum ReviewRequestGate: String, Sendable, Equatable {
    /// Another live opportunity is waiting (first come, first served).
    case pendingOpportunity
    /// ``ReviewRequestPolicy/minimumGap`` since the last attempt has not passed.
    case minimumGap
    /// ``ReviewRequestPolicy/sourceCooldown`` for this source has not passed.
    case sourceCooldown
}
