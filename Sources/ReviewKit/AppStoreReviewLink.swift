import Foundation

/// Deep links to the App Store review flow, for an explicit "Rate this app"
/// entry in settings — motivated users should never have to wait for the
/// system prompt (which may simply never appear).
public enum AppStoreReviewLink {
    /// Opens the App Store product page with the review composer.
    /// - Parameter appID: numeric App Store ID, e.g. `"6472678068"`.
    public static func writeReviewURL(appID: String) -> URL? {
        URL(string: "https://apps.apple.com/app/id\(appID)?action=write-review")
    }
}
