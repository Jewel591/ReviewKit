import Foundation

/// Key-value persistence boundary for review-prompt bookkeeping.
///
/// The default implementation is backed by `UserDefaults`. Hosts can substitute
/// any store (app group defaults, file-backed, in-memory for tests) as long as
/// values survive relaunches with the same semantics.
@MainActor
public protocol ReviewPromptStoring: AnyObject {
    func integer(forKey key: String) -> Int
    func set(_ value: Int, forKey key: String)
    func date(forKey key: String) -> Date?
    func set(_ value: Date, forKey key: String)
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    func containsValue(forKey key: String) -> Bool
}

/// `UserDefaults`-backed store, the production default.
@MainActor
public final class UserDefaultsReviewPromptStore: ReviewPromptStoring {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func integer(forKey key: String) -> Int { defaults.integer(forKey: key) }
    public func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }

    public func date(forKey key: String) -> Date? { defaults.object(forKey: key) as? Date }
    public func set(_ value: Date, forKey key: String) { defaults.set(value, forKey: key) }

    public func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }

    public func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    public func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }

    public func containsValue(forKey key: String) -> Bool { defaults.object(forKey: key) != nil }
}
