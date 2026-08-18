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

The host supplies two things: the name of one core win event, and any
app-specific suppressors. Thresholds are `StandardReviewPolicy` (defined in
`Sources/ReviewKit/StandardReviewPolicy.swift`) — do not fork them per app.

```swift
import ReviewKit

static let engine = ReviewKit.ReviewRequestEngine(
    conditions: StandardReviewPolicy.conditions(coreEvent: "recordSaved")
)
```

That constructor is not a complete integration. Agents must load
[`.agents/skills/integrate-reviewkit/SKILL.md`](.agents/skills/integrate-reviewkit/SKILL.md)
before writing host code: when *not* to adopt, how to pick the win event,
where `recordSession()` goes, coordinator arbitration, every schedule
trigger, settings-page fallback, and shipped-key migration. Humans following
along should read the same file.

## Requirements

- iOS 17 / macOS 14 / watchOS 10 / tvOS 17 / visionOS 1
- Swift 6

## Installation

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "0.1.0")
```

## License

MIT
