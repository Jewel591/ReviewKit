# ReviewKit

Policy engine for App Store review prompts. Decides **whether** the app is
allowed to ask for a review and **when** to actually fire the request — and
nothing else. No UI, no StoreKit dependency, no analytics SDK.

## Scope

One sentence: manage the eligibility and timing of `requestReview()` calls.

Explicitly out of scope:

- Any prompt UI (pre-prompts, "enjoying the app?" dialogs)
- Satisfaction routing (happy → rating, unhappy → feedback) — that belongs to
  the host or a support module, which *calls into* this kit
- NPS collection, analytics pipelines

## Design

```
signals in                 engine                        host
──────────────   ┌──────────────────────────┐   ────────────────────
recordSession()  │ conditions (composable)  │   observes isEligible
recordSignifi-   │ → isEligible (@Observable│ → schedules via
  cantEvent()    │   , persisted pending)   │   ReviewRequestScheduler
                 │ canRequestNow()          │ → calls requestReview()
                 │ recordRequested()        │ ← reports back
                 └──────────────────────────┘
```

- **Conditions** (specification pattern): compose built-ins with your own.
  Built-ins: `MinimumDaysSinceInstallCondition`, `MinimumSessionsCondition`,
  `MinimumSignificantEventsCondition` (per-named-event or total),
  `CooldownCondition`, `NotRequestedForCurrentVersionCondition`,
  `QuietPeriodCondition`, `CustomReviewCondition`.
- **Request-time revalidation**: eligibility can be established long before
  the request fires (the pending flag persists across launches). Conditions
  declare `revalidatesAtRequestTime`; time-based gates are re-checked at the
  moment of the actual call via `canRequestNow()`.
- **Scheduler**: initial delay after the win moment, live gate re-evaluation
  on every attempt, bounded retries while blocked by presentation state, and
  it never consumes eligibility on failure.
- **Persistence contract**: every storage key is customizable
  (`ReviewPromptStorageKeys`), so apps migrating from an in-house
  implementation keep shipped users' counters and cooldowns.
- **Events out**: `ReviewKitEvent` (`becameEligible` / `blocked` /
  `requestRecorded`) for your logging or analytics pipeline.

### Platform semantics this kit encodes

`requestReview()` has no "was shown" callback, and the system displays the
prompt at most 3 times per 365 days. The engine stamps the cooldown on
*attempt*, not display — an ignored attempt still burns the local budget by
design. Keep total attempts low; that is what the version gate and cooldown
are for.

## Usage

```swift
import ReviewKit

@MainActor
enum ReviewPrompt {
    static let engine = ReviewRequestEngine(
        conditions: [
            MinimumSessionsCondition(sessions: 5),
            MinimumSignificantEventsCondition(count: 10, event: "recordSaved"),
            MinimumDaysSinceInstallCondition(days: 7),
            CooldownCondition(days: 120),
            NotRequestedForCurrentVersionCondition(),
            QuietPeriodCondition(
                identifier: "quietPeriod(marketingPrompt)",
                quietInterval: 24 * 3600,
                lastEventDate: { MarketingPrompts.lastShownDate }
            ),
            CustomReviewCondition(identifier: "noRecentCrash") { _ in
                !CrashState.crashedLastLaunch
            },
        ],
        keys: ReviewPromptStorageKeys(namespace: "reviewPrompt"),
        onEvent: { event in Analytics.track(event) }
    )

    static let scheduler = ReviewRequestScheduler()
}
```

In the view layer (SwiftUI):

```swift
@Environment(\.requestReview) private var requestReview

.onChange(of: ReviewPrompt.engine.isEligible) { _, eligible in
    guard eligible else { return }
    ReviewPrompt.scheduler.scheduleIfPossible(
        shouldRequest: { ReviewPrompt.engine.isEligible },
        isBlocked: { scenePhase != .active },
        canRequestNow: { ReviewPrompt.engine.canRequestNow() },
        request: {
            requestReview()
            ReviewPrompt.engine.recordRequested()
        }
    )
}
```

Signals from anywhere in the app:

```swift
ReviewPrompt.engine.recordSession()                    // once per cold start
ReviewPrompt.engine.recordSignificantEvent("recordSaved")
```

Settings-page fallback for motivated users who never see the prompt:

```swift
if let url = AppStoreReviewLink.writeReviewURL(appID: "1234567890") {
    Link("Rate this app", destination: url)
}
```

> Note: if an observable blocking state appears (scene inactive, an overlay
> coordinated by your sheet system), call `scheduler.cancel()` and re-schedule
> with fresh closures when it clears — captured `@Environment` values do not
> track later updates. See the `ReviewRequestScheduler` doc comment.

## Migrating from an existing implementation

Map `ReviewPromptStorageKeys` onto your historical keys so shipped users keep
their counters and cooldown. A predecessor with a single undifferentiated
action counter can alias every event name onto that key (the engine will not
double-count when the event key equals the total key). See
`StorageKeyMigrationTests` for a worked example.

## Requirements

- iOS 17 / macOS 14 / watchOS 10 / tvOS 17 / visionOS 1
- Swift 6

## Installation

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "0.1.0")
```

## License

MIT
