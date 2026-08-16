import Foundation

/// Analytics/diagnostics hook. ReviewKit emits these; the host forwards them
/// to its own logging or analytics pipeline to learn which triggers work.
public enum ReviewKitEvent: Sendable, Equatable {
    /// All conditions passed; the pending flag is now set.
    case becameEligible
    /// An evaluation pass stopped at this condition.
    case blocked(conditionID: String, reason: String?)
    /// The host reported that it called `requestReview()`; cooldown and
    /// per-version anchors were stamped.
    case requestRecorded
}
