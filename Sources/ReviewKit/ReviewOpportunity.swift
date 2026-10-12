import Foundation

/// Names the business moment that offered a review opportunity, e.g.
/// `"purchase"` or `"record_milestone"`.
///
/// Used as the per-source cooldown key suffix and as the analytics `source`
/// value, so keep it a short stable `snake_case` identifier and never rename a
/// shipped one (renaming resets that source's cooldown).
public struct ReviewRequestSource: Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }
}

/// One in-memory chance to ask for a review. Never persisted: it dies with the
/// process or at ``deadline``, whichever comes first.
public struct ReviewOpportunity: Equatable, Sendable {
    public let id: UUID
    public let source: ReviewRequestSource
    public let offeredAt: Date
    public let deadline: Date

    init(source: ReviewRequestSource, offeredAt: Date) {
        self.id = UUID()
        self.source = source
        self.offeredAt = offeredAt
        self.deadline = offeredAt.addingTimeInterval(ReviewRequestPolicy.opportunityLifetime)
    }

    func isExpired(at now: Date) -> Bool {
        now >= deadline
    }
}
