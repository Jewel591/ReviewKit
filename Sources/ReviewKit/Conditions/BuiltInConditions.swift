import Foundation

/// Requires the app to have been installed for at least N whole days.
public struct MinimumDaysSinceInstallCondition: ReviewRequestCondition {
    public let identifier = "minimumDaysSinceInstall"
    public let days: Int

    public init(days: Int) {
        self.days = days
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        // Unknown install date blocks rather than passes: the engine stamps it
        // on first init, so "unknown" only happens with a broken store.
        guard let elapsed = context.daysSinceFirstLaunch else {
            return .blocked("install date unknown")
        }
        guard elapsed >= days else {
            return .blocked("days since install \(elapsed) < \(days)")
        }
        return .satisfied
    }
}

/// Requires at least N cold-start sessions.
public struct MinimumSessionsCondition: ReviewRequestCondition {
    public let identifier = "minimumSessions"
    public let sessions: Int

    public init(sessions: Int) {
        self.sessions = sessions
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        guard context.sessionCount >= sessions else {
            return .blocked("sessions \(context.sessionCount) < \(sessions)")
        }
        return .satisfied
    }
}

/// Requires at least N significant events — either of one named event or of
/// the total across all events (`event: nil`).
public struct MinimumSignificantEventsCondition: ReviewRequestCondition {
    public let identifier: String
    public let count: Int
    public let event: String?

    public init(count: Int, event: String? = nil) {
        self.count = count
        self.event = event
        self.identifier =
            event.map { "minimumSignificantEvents(\($0))" } ?? "minimumSignificantEvents"
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        let current: Int
        if let event {
            current = context.significantEventCount(of: event)
        } else {
            current = context.totalSignificantEventCount
        }
        guard current >= count else {
            return .blocked("significant events \(current) < \(count)")
        }
        return .satisfied
    }
}

/// Blocks for N whole days after the previous request attempt.
///
/// Re-validated at request time: the pending flag can persist across launches,
/// and the cooldown must hold at the moment the prompt actually fires.
public struct CooldownCondition: ReviewRequestCondition {
    public let identifier = "cooldown"
    public let revalidatesAtRequestTime = true
    public let days: Int

    public init(days: Int) {
        self.days = days
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        guard let elapsed = context.daysSinceLastRequest else { return .satisfied }
        guard elapsed >= days else {
            return .blocked("cooldown \(elapsed) < \(days) days")
        }
        return .satisfied
    }
}

/// At most one request attempt per app version.
///
/// Apple already caps the system prompt at three displays per 365 days; this
/// gate keeps the *attempts* budget from being burned inside a single version.
public struct NotRequestedForCurrentVersionCondition: ReviewRequestCondition {
    public let identifier = "notRequestedForCurrentVersion"
    public let revalidatesAtRequestTime = true

    public init() {}

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        guard context.lastRequestVersion != context.currentVersion else {
            return .blocked("already requested for version \(context.currentVersion)")
        }
        return .satisfied
    }
}

/// Blocks within a quiet interval after some host-side event (marketing
/// prompt shown, crash, feedback submitted, paywall seen...).
///
/// The kit stays ignorant of what the event is; the host supplies the date of
/// the most recent occurrence.
public struct QuietPeriodCondition: ReviewRequestCondition {
    public let identifier: String
    public let revalidatesAtRequestTime = true
    public let quietInterval: TimeInterval
    private let lastEventDate: @MainActor () -> Date?

    /// - Parameters:
    ///   - identifier: names the event class, e.g. `"quietPeriod(marketingPrompt)"`.
    ///   - quietInterval: seconds that must elapse since the event.
    ///   - lastEventDate: most recent occurrence; `nil` means it never happened.
    public init(
        identifier: String,
        quietInterval: TimeInterval,
        lastEventDate: @escaping @MainActor () -> Date?
    ) {
        self.identifier = identifier
        self.quietInterval = quietInterval
        self.lastEventDate = lastEventDate
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        guard let eventDate = lastEventDate() else { return .satisfied }
        let elapsed = context.now.timeIntervalSince(eventDate)
        guard elapsed >= quietInterval else {
            return .blocked("quiet period \(Int(elapsed))s < \(Int(quietInterval))s")
        }
        return .satisfied
    }
}

/// Arbitrary host-defined gate.
///
/// Defaults to re-validating at request time because host state (paywall
/// visible, recent crash...) can change between eligibility and firing;
/// pass `revalidatesAtRequestTime: false` only for monotonic conditions.
public struct CustomReviewCondition: ReviewRequestCondition {
    public let identifier: String
    public let revalidatesAtRequestTime: Bool
    private let predicate: @MainActor (ReviewRequestContext) -> ReviewConditionVerdict

    public init(
        identifier: String,
        revalidatesAtRequestTime: Bool = true,
        predicate: @escaping @MainActor (ReviewRequestContext) -> ReviewConditionVerdict
    ) {
        self.identifier = identifier
        self.revalidatesAtRequestTime = revalidatesAtRequestTime
        self.predicate = predicate
    }

    /// Boolean convenience; blocked reason is the identifier itself.
    public init(
        identifier: String,
        revalidatesAtRequestTime: Bool = true,
        isSatisfied: @escaping @MainActor (ReviewRequestContext) -> Bool
    ) {
        self.init(identifier: identifier, revalidatesAtRequestTime: revalidatesAtRequestTime) {
            isSatisfied($0) ? .satisfied : .blocked(identifier)
        }
    }

    public func evaluate(_ context: ReviewRequestContext) -> ReviewConditionVerdict {
        predicate(context)
    }
}
