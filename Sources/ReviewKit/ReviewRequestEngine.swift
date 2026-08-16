import Foundation
import Observation

/// Eligibility engine: decides *whether the app is allowed to ask* for a
/// review right now. It never presents UI and never calls StoreKit — the host
/// observes `isEligible`, schedules the actual call (see
/// ``ReviewRequestScheduler``), invokes the platform `requestReview()`, then
/// reports back via ``recordRequested()``.
///
/// Platform semantics worth internalizing: `requestReview()` has **no
/// "was shown" callback**. Calling it only tells StoreKit you'd like the
/// prompt; the system may silently ignore it (hard cap of 3 displays per 365
/// days). The engine therefore stamps the cooldown on *attempt*, not display —
/// an unanswered attempt still burns the local budget by design.
@MainActor
@Observable
public final class ReviewRequestEngine {
    /// True when all conditions passed and the request has not been consumed.
    /// Persisted across launches until ``recordRequested()`` is called.
    public private(set) var isEligible: Bool

    @ObservationIgnored private let conditions: [any ReviewRequestCondition]
    @ObservationIgnored private let store: any ReviewPromptStoring
    @ObservationIgnored private let keys: ReviewPromptStorageKeys
    @ObservationIgnored private let dateProvider: any ReviewDateProviding
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let onEvent: ((ReviewKitEvent) -> Void)?

    /// - Parameters:
    ///   - conditions: evaluated in order; all must pass. Order matters only
    ///     for which gate gets reported in `blocked` events (first failure).
    ///   - store: persistence; defaults to `UserDefaults.standard`.
    ///   - keys: key contract; customize to migrate from historical keys.
    ///   - currentVersion: defaults to `CFBundleShortVersionString`.
    ///   - dateProvider: injectable clock.
    ///   - onEvent: analytics/diagnostics sink.
    public init(
        conditions: [any ReviewRequestCondition],
        store: (any ReviewPromptStoring)? = nil,
        keys: ReviewPromptStorageKeys = ReviewPromptStorageKeys(),
        currentVersion: String? = nil,
        dateProvider: any ReviewDateProviding = SystemReviewDateProvider(),
        onEvent: ((ReviewKitEvent) -> Void)? = nil
    ) {
        self.conditions = conditions
        self.store = store ?? UserDefaultsReviewPromptStore()
        self.keys = keys
        self.currentVersion =
            currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        self.dateProvider = dateProvider
        self.onEvent = onEvent

        if !self.store.containsValue(forKey: keys.firstLaunchDate) {
            self.store.set(dateProvider.now, forKey: keys.firstLaunchDate)
        }
        self.isEligible = self.store.bool(forKey: keys.pendingRequest)
    }

    // MARK: - Signals in

    /// Call once per cold start. The session itself may cross the last gate,
    /// so eligibility is re-evaluated immediately after counting.
    public func recordSession() {
        store.set(store.integer(forKey: keys.sessionCount) + 1, forKey: keys.sessionCount)
        evaluateEligibility()
    }

    /// Count one or more occurrences of a named significant event (a "win" —
    /// the app's core value moment) and re-evaluate eligibility.
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
        evaluateEligibility()
    }

    // MARK: - Decision points

    /// Full evaluation pass. Called automatically by the record methods;
    /// call directly when a host-side suppressor state changes (e.g. a quiet
    /// period elapsed) and you want eligibility re-checked without new signals.
    public func evaluateEligibility() {
        guard !isEligible else { return }
        let context = makeContext()
        for condition in conditions {
            let verdict = condition.evaluate(context)
            if !verdict.isSatisfied {
                onEvent?(.blocked(conditionID: condition.identifier, reason: verdict.reason))
                return
            }
        }
        store.set(true, forKey: keys.pendingRequest)
        isEligible = true
        onEvent?(.becameEligible)
    }

    /// Final check at the moment of the actual `requestReview()` call.
    ///
    /// Requires established eligibility — this is a *revalidation*, not an
    /// independent decision, so it can never approve a request that
    /// ``evaluateEligibility()`` has not approved first. On top of that,
    /// every condition that declared `revalidatesAtRequestTime` is re-run
    /// against a fresh context, because eligibility and firing can be
    /// arbitrarily far apart (the pending flag persists across launches).
    public func canRequestNow() -> Bool {
        guard isEligible else { return false }
        let context = makeContext()
        for condition in conditions where condition.revalidatesAtRequestTime {
            let verdict = condition.evaluate(context)
            if !verdict.isSatisfied {
                onEvent?(.blocked(conditionID: condition.identifier, reason: verdict.reason))
                return false
            }
        }
        return true
    }

    /// Call immediately after invoking the platform `requestReview()`:
    /// consumes the pending flag and stamps the cooldown + per-version anchors.
    public func recordRequested() {
        isEligible = false
        store.set(false, forKey: keys.pendingRequest)
        store.set(dateProvider.now, forKey: keys.lastRequestDate)
        store.set(currentVersion, forKey: keys.lastRequestVersion)
        onEvent?(.requestRecorded)
    }

    // MARK: - Private

    private func makeContext() -> ReviewRequestContext {
        ReviewRequestContext(
            now: dateProvider.now,
            firstLaunchDate: store.date(forKey: keys.firstLaunchDate),
            sessionCount: store.integer(forKey: keys.sessionCount),
            totalSignificantEventCount: store.integer(forKey: keys.significantEventTotal),
            lastRequestDate: store.date(forKey: keys.lastRequestDate),
            lastRequestVersion: store.string(forKey: keys.lastRequestVersion),
            currentVersion: currentVersion,
            eventCountProvider: { [store, keys] name in
                store.integer(forKey: keys.significantEventKey(name))
            }
        )
    }
}
