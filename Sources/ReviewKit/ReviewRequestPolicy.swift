import Foundation

/// Fixed request throttles shared by every app in the portfolio.
///
/// The app decides *which* moments are worth asking at (``ReviewRequestEngine/offer(source:)``);
/// these numbers only keep the attempts rare. They throttle local request
/// **attempts** — they are not Apple's display quota. Apple caps actual
/// displays (3 per 365 days for a user who has not rated) and reports nothing
/// back, so the app cannot know whether an attempt was shown.
///
/// Deliberately not configurable per app: no product has shown a need for
/// different values, and per-app knobs would quietly fork the standard.
public enum ReviewRequestPolicy {
    /// Minimum time between any two request attempts, regardless of source.
    /// Keeps two different win moments that land close together (a purchase
    /// right after the third record) from asking twice in a row.
    public static let minimumGap: TimeInterval = 14 * 86_400

    /// Minimum time before the same source may ask again.
    public static let sourceCooldown: TimeInterval = 365 * 86_400

    /// How long an offered opportunity stays valid. Measured from the offer,
    /// never extended by cancelling or re-scheduling. A win moment that could
    /// not be served within this window is no longer the moment.
    public static let opportunityLifetime: TimeInterval = 180
}
