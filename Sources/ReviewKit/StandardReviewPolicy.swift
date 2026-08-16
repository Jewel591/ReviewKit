import Foundation

/// The house-standard condition set. Apps in the portfolio should use this
/// instead of hand-picking thresholds, so review-prompt behavior stays one
/// standard across products.
///
/// An app supplies exactly two things: what its core "win" event is, and any
/// app-specific suppressors (recent crash, paywall visible, feedback just
/// submitted...). Everything else is fixed policy:
///
/// - **7 days since install** — prompt only users experienced enough to give
///   informed feedback (Apple's guidance: delay until people know the app).
/// - **5 sessions** — filters drive-by installs; a returning user has opted
///   back in at least four times.
/// - **10 core events** — the user has repeatedly reached the app's value
///   moment, not just wandered past it.
/// - **120-day cooldown** — self-imposed cap well under Apple's 3-per-365
///   system budget, so one unhappy stretch is not compounded by re-prompting.
/// - **once per app version** — a version gets one attempt; the next attempt
///   waits for the next release (and the cooldown).
///
/// Changing a number here is a portfolio-wide policy decision; do it in this
/// file, not by bypassing the preset in one app.
public enum StandardReviewPolicy {
    public static let minimumDaysSinceInstall = 7
    public static let minimumSessions = 5
    public static let coreEventThreshold = 10
    public static let cooldownDays = 120

    /// The standard condition set.
    ///
    /// Deliberately offers no threshold knobs: apps that could quietly tweak
    /// numbers while still claiming "standard policy" would silently fork the
    /// portfolio standard. A genuinely divergent product hand-assembles its
    /// own conditions array under its own policy name.
    ///
    /// - Parameters:
    ///   - coreEvent: name of the app's core success event
    ///     (e.g. `"recordSaved"` for a finance tracker). Recorded via
    ///     `ReviewRequestEngine.recordSignificantEvent(_:count:)`.
    ///   - suppressors: app-specific blocking conditions, appended after the
    ///     standard gates. Build them with ``QuietPeriodCondition`` /
    ///     ``CustomReviewCondition``.
    @MainActor
    public static func conditions(
        coreEvent: String,
        suppressors: [any ReviewRequestCondition] = []
    ) -> [any ReviewRequestCondition] {
        [
            MinimumDaysSinceInstallCondition(days: minimumDaysSinceInstall),
            MinimumSessionsCondition(sessions: minimumSessions),
            MinimumSignificantEventsCondition(count: coreEventThreshold, event: coreEvent),
            CooldownCondition(days: cooldownDays),
            NotRequestedForCurrentVersionCondition(),
        ] + suppressors
    }
}
