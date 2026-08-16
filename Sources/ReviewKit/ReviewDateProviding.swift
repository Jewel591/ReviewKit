import Foundation

/// Injectable clock so time-based conditions are testable.
public protocol ReviewDateProviding: Sendable {
    var now: Date { get }
}

public struct SystemReviewDateProvider: ReviewDateProviding {
    public init() {}
    public var now: Date { Date() }
}
