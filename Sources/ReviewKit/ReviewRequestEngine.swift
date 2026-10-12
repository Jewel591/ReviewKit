import Foundation
import Observation

/// Project-initiated review requests.
///
/// The app decides *when* a moment is worth asking at and calls
/// ``offer(source:)`` right after that win (purchase succeeded, third record
/// saved...). The engine keeps the attempts rare (``ReviewRequestPolicy``)
/// and holds at most one in-memory opportunity until
/// a host (``SwiftUICore/View/reviewRequestHost(engine:isBlocked:hasBlockingPresentation:perform:)``
/// or ``ReviewRequestScheduler``) finds a quiet moment to serve it.
///
/// Platform semantics worth internalizing: `requestReview()` has **no "was
/// shown" callback**. The system may silently ignore the call (Apple caps
/// displays at 3 per 365 days for a user who has not rated). Cooldowns are
/// stamped on *attempt*, never on display, and an ignored attempt is never
/// retried.
///
/// App-specific "not now" rules (a marketing prompt just showed, a celebration
/// is playing) stay in the host: skip the ``offer(source:)`` call in the host
/// function that owns the moment, or report the state through the host's
/// `isBlocked`.
@MainActor
@Observable
public final class ReviewRequestEngine {
    /// The current opportunity, if any. In memory only: it never survives a
    /// relaunch, and it is dropped once its deadline passes.
    public private(set) var pendingOpportunity: ReviewOpportunity?

    @ObservationIgnored private let store: any ReviewPromptStoring
    @ObservationIgnored private let keys: ReviewPromptStorageKeys
    @ObservationIgnored private let dateProvider: any ReviewDateProviding
    @ObservationIgnored private let onEvent: ((ReviewKitEvent) -> Void)?

    /// - Parameters:
    ///   - store: persistence; defaults to `UserDefaults.standard`.
    ///   - keys: key contract; customize to keep shipped users' state.
    ///   - dateProvider: injectable clock.
    ///   - onEvent: analytics/diagnostics sink.
    public init(
        store: (any ReviewPromptStoring)? = nil,
        keys: ReviewPromptStorageKeys = ReviewPromptStorageKeys(),
        dateProvider: any ReviewDateProviding = SystemReviewDateProvider(),
        onEvent: ((ReviewKitEvent) -> Void)? = nil
    ) {
        self.store = store ?? UserDefaultsReviewPromptStore()
        self.keys = keys
        self.dateProvider = dateProvider
        self.onEvent = onEvent

        // 0.x persisted a pending request across launches. 1.0 opportunities
        // come only from a fresh win moment, so a stale flag must never be
        // replayed after an upgrade.
        if self.store.bool(forKey: keys.legacyPendingRequest) {
            self.store.set(false, forKey: keys.legacyPendingRequest)
        }
    }

    // MARK: - Counters

    /// Count occurrences of a named success event. Hosts read the count back
    /// with ``significantEventCount(_:)`` to decide on their own milestone
    /// (e.g. "third successful save"). Counting never offers by itself.
    public func recordSignificantEvent(_ name: String, count: Int = 1) {
        guard count > 0 else { return }
        let eventKey = keys.significantEventKey(name)
        store.set(store.integer(forKey: eventKey) + count, forKey: eventKey)
        // Legacy single-counter migrations may map every event name onto the
        // total key itself; skip the second write to avoid double counting.
        if eventKey != keys.significantEventTotal {
            store.set(
                store.integer(forKey: keys.significantEventTotal) + count,
                forKey: keys.significantEventTotal
            )
        }
    }

    public func significantEventCount(_ name: String) -> Int {
        store.integer(forKey: keys.significantEventKey(name))
    }

    // MARK: - Opportunities

    /// Offers a review opportunity for a win moment that just happened.
    ///
    /// Call only after the success is final (saved, purchased with the
    /// entitlement active), never on launch or on a settings button. Returns
    /// `true` when the opportunity was accepted; it is rejected when another
    /// live opportunity is pending (first come, first served), a throttle is
    /// still running.
    @discardableResult
    public func offer(source: ReviewRequestSource) -> Bool {
        let now = dateProvider.now
        if let pending = pendingOpportunity {
            if pending.isExpired(at: now) {
                expire(pending)
            } else {
                block(source, .pendingOpportunity, "opportunity from \(pending.source) still pending")
                return false
            }
        }
        guard passesGates(for: source, now: now) else { return false }
        pendingOpportunity = ReviewOpportunity(source: source, offeredAt: now)
        onEvent?(.offered(source: source))
        return true
    }

    /// Whether the pending opportunity may be served right now: present, not
    /// expired, throttles clear. An expired opportunity is
    /// dropped as a side effect.
    public func canRequestNow() -> Bool {
        guard let opportunity = livePendingOpportunity() else { return false }
        return passesGates(for: opportunity.source, now: dateProvider.now)
    }

    /// The single request exit. Re-checks every gate, then runs `perform`,
    /// which must call the platform `requestReview()` synchronously and
    /// return `true`, or return `false` without calling it (e.g. a surface
    /// arbiter refused). Only `true` stamps the cooldowns, consumes the
    /// opportunity and emits ``ReviewKitEvent/requestRecorded(source:)``;
    /// `false` leaves the opportunity for a retry before its deadline.
    @discardableResult
    public func performRequest(_ perform: () -> Bool) -> Bool {
        guard canRequestNow(), let opportunity = pendingOpportunity else { return false }
        guard perform() else { return false }
        let now = dateProvider.now
        store.set(now, forKey: keys.lastRequestDate)
        store.set(now, forKey: keys.sourceLastRequestDateKey(opportunity.source))
        pendingOpportunity = nil
        onEvent?(.requestRecorded(source: opportunity.source))
        return true
    }

    /// Returns the pending opportunity if it is still within its deadline,
    /// dropping it otherwise.
    @discardableResult
    public func livePendingOpportunity() -> ReviewOpportunity? {
        guard let opportunity = pendingOpportunity else { return nil }
        guard !opportunity.isExpired(at: dateProvider.now) else {
            expire(opportunity)
            return nil
        }
        return opportunity
    }

    var now: Date { dateProvider.now }

    // MARK: - Private

    private func expire(_ opportunity: ReviewOpportunity) {
        guard pendingOpportunity?.id == opportunity.id else { return }
        pendingOpportunity = nil
        onEvent?(.expired(source: opportunity.source))
    }

    private func passesGates(for source: ReviewRequestSource, now: Date) -> Bool {
        if let last = store.date(forKey: keys.lastRequestDate),
            now.timeIntervalSince(last) < ReviewRequestPolicy.minimumGap
        {
            block(source, .minimumGap, "last request \(Self.days(now, last)) days ago")
            return false
        }
        if let last = store.date(forKey: keys.sourceLastRequestDateKey(source)),
            now.timeIntervalSince(last) < ReviewRequestPolicy.sourceCooldown
        {
            block(source, .sourceCooldown, "\(source) requested \(Self.days(now, last)) days ago")
            return false
        }
        return true
    }

    private func block(_ source: ReviewRequestSource, _ gate: ReviewRequestGate, _ reason: String) {
        onEvent?(.blocked(source: source, gate: gate, reason: reason))
    }

    private static func days(_ now: Date, _ then: Date) -> Int {
        Int(now.timeIntervalSince(then) / 86_400)
    }
}
