import Foundation

/// Outcome of evaluating a single condition.
public struct ReviewConditionVerdict: Sendable, Equatable {
    public let isSatisfied: Bool
    /// Human-readable reason when blocked; surfaces in `ReviewKitEvent.blocked`
    /// so hosts can log which gate is holding the prompt back.
    public let reason: String?

    public static let satisfied = ReviewConditionVerdict(isSatisfied: true, reason: nil)

    public static func blocked(_ reason: String) -> ReviewConditionVerdict {
        ReviewConditionVerdict(isSatisfied: false, reason: reason)
    }
}

/// A single gate in the eligibility policy (specification pattern).
///
/// Conditions compose: the engine prompts only when every configured condition
/// is satisfied. Hosts add app-specific suppressors (crashed recently, paywall
/// on screen, feedback just submitted...) via ``CustomReviewCondition`` without
/// the kit knowing about those domains.
@MainActor
public protocol ReviewRequestCondition {
    /// Stable identifier used in events and logs.
    var identifier: String { get }

    /// Whether this condition must be re-checked at the moment the request is
    /// actually fired, not only when eligibility was first established.
    ///
    /// Eligibility can be established long before the request fires (the
    /// pending flag persists across launches), so time-based gates — cooldown,
    /// per-version, quiet periods — must return `true` here. Pure progress
    /// counters (sessions, events) never regress and can return `false`.
    var revalidatesAtRequestTime: Bool { get }

    func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict
}

extension ReviewRequestCondition {
    public var revalidatesAtRequestTime: Bool { false }
}
