# ReviewKit

Project-initiated App Store review requests. The app says **which moment is
worth asking at**; the kit keeps attempts rare, waits for a quiet moment and
makes the platform call exactly once. No prompt UI, no StoreKit dependency, no
analytics SDK.

## Scope

One sentence: serve the app's chosen review moments with `requestReview()`,
rarely and at the right time.

Explicitly out of scope:

- Any prompt UI (pre-prompts, "enjoying the app?" dialogs)
- Satisfaction routing (happy → rating, unhappy → feedback) — that belongs to
  the host or a support module, which *calls into* this kit
- Unified eligibility thresholds (install age, session count, N successes).
  The app expresses "worth asking" by where it calls `offer(source:)`.
- NPS collection, analytics pipelines

## Design

```
app win moment              engine                         host view
──────────────   ┌───────────────────────────┐   ──────────────────────────
offer(source:)   │ throttles                 │   .reviewRequestHost(...)
                 │ → pendingOpportunity      │ → waits for a quiet moment
                 │   (in memory, 180s life)  │ → perform: requestReview()
                 │ performRequest(perform)   │ ← true = attempted
                 └───────────────────────────┘
```

- **Opportunities**: `offer(source:)` right after a final success (purchase
  with entitlement active, a saved record...). At most one live opportunity,
  first come first served, never persisted, dropped 180 seconds after the
  offer. Cancelling or re-scheduling never extends that deadline.
- **Throttles** (`ReviewRequestPolicy`, fixed, not configurable): 14 days
  between any two attempts, 365 days before the same source asks again. These
  throttle local *attempts*; they are not Apple's display quota.
- **App rules stay in the app**: "not right after a marketing prompt" or
  "only users who saved once" are decided in the host function that calls
  `offer(source:)`; states that must not be interrupted at request time go
  into the host's `isBlocked`. The kit has no condition DSL.
- **Single request exit**: `performRequest(_:)` re-checks every gate and
  runs the host's `perform` closure. Only `true` (the platform call happened)
  stamps cooldowns and emits `requestRecorded(source:)`; `false` (e.g. the
  app's surface arbiter refused) keeps the opportunity for a retry before the
  deadline.
- **SwiftUI host**: `.reviewRequestHost(engine:isBlocked:hasBlockingPresentation:perform:)`
  owns the scheduler, treats a non-active `scenePhase` as blocked, cancels
  while the host is blocked and re-schedules when it clears.
- **Counters**: `recordSignificantEvent(_:)` / `significantEventCount(_:)`
  let the host define its own milestones ("third successful save"). Counting
  never offers by itself.
- **Persistence contract**: every storage key is customizable
  (`ReviewPromptStorageKeys`), so shipped users keep counters and the last
  request date.
- **Events out**: `ReviewKitEvent` (`offered` / `blocked` / `expired` /
  `requestRecorded`, each with its source) for logging or analytics.

### Platform semantics this kit encodes

`requestReview()` has no "was shown" or "was rated" callback. In development
builds the system shows a test prompt; in TestFlight the request does
nothing; in App Store builds the system decides and the app cannot find out.
Cooldowns are stamped on *attempt*, and an ignored attempt is never retried.
`requestRecorded` therefore means "we asked", never "the prompt appeared".

## Usage

```swift
import ReviewKit

@MainActor
enum ReviewPrompt {
    static let engine = ReviewKit.ReviewRequestEngine(
        keys: ReviewPromptStorageKeys(namespace: "reviewPrompt")
    )

    /// Right after the purchase succeeded with the entitlement active.
    static func purchaseSucceeded() {
        engine.offer(source: "purchase")
    }
}

// Once, at the scene root:
@Environment(\.requestReview) private var requestReview

content.reviewRequestHost(engine: ReviewPrompt.engine, isBlocked: isShowingAppSurface) {
    requestReview()
    return true
}
```

That is not a complete integration. Agents must load
[`.agents/skills/integrate-reviewkit/SKILL.md`](.agents/skills/integrate-reviewkit/SKILL.md)
before writing host code: how to choose moments, blockers, surface
arbitration inside `perform`, analytics, and migrating from 0.x.

UIKit hosts can drive `ReviewRequestScheduler` directly; the SwiftUI host is
the supported path in 1.0.

## Upgrading from 0.x

1.0 removes `StandardReviewPolicy`, the condition types
(`ReviewRequestCondition`, `QuietPeriodCondition`, `CustomReviewCondition`),
session counting, the per-version gate and the persisted pending flag. Each app must
choose its own moments while migrating; see the skill. Apps pinned with
`from: "0.x"` stay on 0.x until they migrate.

## Requirements

- iOS 17 / macOS 14 / watchOS 10 / tvOS 17 / visionOS 1
- Swift 6

## Installation

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "1.0.0")
```

## License

MIT
