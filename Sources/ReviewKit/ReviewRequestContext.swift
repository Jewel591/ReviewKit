import Foundation

/// Immutable snapshot handed to conditions during evaluation.
///
/// Conditions never touch the store directly; the engine builds one context
/// per evaluation pass so all conditions see a consistent state.
public struct ReviewRequestContext {
    public let now: Date
    public let firstLaunchDate: Date?
    public let sessionCount: Int
    public let totalSignificantEventCount: Int
    public let lastRequestDate: Date?
    public let lastRequestVersion: String?
    public let currentVersion: String

    private let eventCountProvider: @MainActor (String) -> Int

    public init(
        now: Date,
        firstLaunchDate: Date?,
        sessionCount: Int,
        totalSignificantEventCount: Int,
        lastRequestDate: Date?,
        lastRequestVersion: String?,
        currentVersion: String,
        eventCountProvider: @escaping @MainActor (String) -> Int
    ) {
        self.now = now
        self.firstLaunchDate = firstLaunchDate
        self.sessionCount = sessionCount
        self.totalSignificantEventCount = totalSignificantEventCount
        self.lastRequestDate = lastRequestDate
        self.lastRequestVersion = lastRequestVersion
        self.currentVersion = currentVersion
        self.eventCountProvider = eventCountProvider
    }

    /// Counter for one named significant event.
    @MainActor
    public func significantEventCount(of name: String) -> Int {
        eventCountProvider(name)
    }

    /// Whole days elapsed since first launch, `nil` if unknown.
    public var daysSinceFirstLaunch: Int? {
        guard let firstLaunchDate else { return nil }
        return Calendar.current.dateComponents([.day], from: firstLaunchDate, to: now).day
    }

    /// Whole days elapsed since the last request attempt, `nil` if never requested.
    public var daysSinceLastRequest: Int? {
        guard let lastRequestDate else { return nil }
        return Calendar.current.dateComponents([.day], from: lastRequestDate, to: now).day
    }
}
