import Foundation

@testable import ReviewKit

@MainActor
final class InMemoryStore: ReviewPromptStoring {
    private(set) var storage: [String: Any] = [:]

    func integer(forKey key: String) -> Int { storage[key] as? Int ?? 0 }
    func set(_ value: Int, forKey key: String) { storage[key] = value }
    func date(forKey key: String) -> Date? { storage[key] as? Date }
    func set(_ value: Date, forKey key: String) { storage[key] = value }
    func string(forKey key: String) -> String? { storage[key] as? String }
    func set(_ value: String, forKey key: String) { storage[key] = value }
    func bool(forKey key: String) -> Bool { storage[key] as? Bool ?? false }
    func set(_ value: Bool, forKey key: String) { storage[key] = value }
    func containsValue(forKey key: String) -> Bool { storage[key] != nil }
}

final class MutableDateProvider: ReviewDateProviding, @unchecked Sendable {
    var now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.now = now
    }

    func advance(days: Int) {
        now = now.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

@MainActor
final class EventRecorder {
    private(set) var events: [ReviewKitEvent] = []

    func record(_ event: ReviewKitEvent) {
        events.append(event)
    }

    var blockedConditionIDs: [String] {
        events.compactMap {
            if case .blocked(let id, _) = $0 { return id }
            return nil
        }
    }
}
