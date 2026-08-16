import Foundation

/// Persistence key contract.
///
/// Keys are part of the upgrade contract with shipped app versions: renaming a
/// key silently resets counters and cooldowns for existing users. Every field
/// is customizable so an app migrating from a previous in-house implementation
/// can map onto its historical keys instead of losing state.
public struct ReviewPromptStorageKeys: Sendable {
    /// Cold-start session counter.
    public var sessionCount: String
    /// Sum of all significant events (kept as its own counter so conditions on
    /// the total do not require enumerating per-event keys).
    public var significantEventTotal: String
    /// First-launch timestamp, written once on first engine init.
    public var firstLaunchDate: String
    /// Timestamp of the last `requestReview()` attempt (cooldown anchor).
    public var lastRequestDate: String
    /// App version string of the last request attempt (per-version gate anchor).
    public var lastRequestVersion: String
    /// Persisted pending-eligibility flag (survives relaunch until consumed).
    public var pendingRequest: String
    /// Maps a significant-event name to its counter key.
    public var significantEventKey: @Sendable (String) -> String

    public init(
        sessionCount: String,
        significantEventTotal: String,
        firstLaunchDate: String,
        lastRequestDate: String,
        lastRequestVersion: String,
        pendingRequest: String,
        significantEventKey: @escaping @Sendable (String) -> String
    ) {
        self.sessionCount = sessionCount
        self.significantEventTotal = significantEventTotal
        self.firstLaunchDate = firstLaunchDate
        self.lastRequestDate = lastRequestDate
        self.lastRequestVersion = lastRequestVersion
        self.pendingRequest = pendingRequest
        self.significantEventKey = significantEventKey
    }

    /// Default key set under a namespace, e.g. `reviewKit_sessionCount`.
    public init(namespace: String = "reviewKit") {
        self.init(
            sessionCount: "\(namespace)_sessionCount",
            significantEventTotal: "\(namespace)_significantEventTotal",
            firstLaunchDate: "\(namespace)_firstLaunchDate",
            lastRequestDate: "\(namespace)_lastRequestDate",
            lastRequestVersion: "\(namespace)_lastRequestVersion",
            pendingRequest: "\(namespace)_pendingRequest",
            significantEventKey: { "\(namespace)_significantEvent_\($0)" }
        )
    }
}
