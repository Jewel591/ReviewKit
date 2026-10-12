import Foundation

/// Persistence key contract.
///
/// Keys are part of the upgrade contract with shipped app versions: renaming a
/// key silently resets counters and cooldowns for existing users. Every field
/// is customizable so an app can map onto its historical keys instead of
/// losing state.
public struct ReviewPromptStorageKeys: Sendable {
    /// Sum of all significant events (kept as its own counter so a host can
    /// read the total without enumerating per-event keys).
    public var significantEventTotal: String
    /// Timestamp of the last request attempt from any source (minimum-gap anchor).
    public var lastRequestDate: String
    /// Pre-1.0 persisted pending-eligibility flag. 1.0 never reads it as
    /// eligibility; the engine writes `false` on init so an upgrade cannot
    /// replay a stale pending request.
    public var legacyPendingRequest: String
    /// Maps a significant-event name to its counter key.
    public var significantEventKey: @Sendable (String) -> String
    /// Maps a source to the key holding that source's last request attempt.
    public var sourceLastRequestDateKey: @Sendable (ReviewRequestSource) -> String

    public init(
        significantEventTotal: String,
        lastRequestDate: String,
        legacyPendingRequest: String,
        significantEventKey: @escaping @Sendable (String) -> String,
        sourceLastRequestDateKey: @escaping @Sendable (ReviewRequestSource) -> String
    ) {
        self.significantEventTotal = significantEventTotal
        self.lastRequestDate = lastRequestDate
        self.legacyPendingRequest = legacyPendingRequest
        self.significantEventKey = significantEventKey
        self.sourceLastRequestDateKey = sourceLastRequestDateKey
    }

    /// Default key set under a namespace, e.g. `reviewKit_lastRequestDate`.
    public init(namespace: String = "reviewKit") {
        self.init(
            significantEventTotal: "\(namespace)_significantEventTotal",
            lastRequestDate: "\(namespace)_lastRequestDate",
            legacyPendingRequest: "\(namespace)_pendingRequest",
            significantEventKey: { "\(namespace)_significantEvent_\($0)" },
            sourceLastRequestDateKey: { "\(namespace)_lastRequestDate_\($0.rawValue)" }
        )
    }
}
