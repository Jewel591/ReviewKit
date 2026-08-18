---
name: integrate-reviewkit
description: 在自家 App 矩阵中接入或调整 App Store 评分请求（requestReview 弹窗时机）时必须先加载：一律使用自研公开包 ReviewKit（github.com/Jewel591/ReviewKit）而不是手写计数器或引入第三方评分库。覆盖何时接入/不接入、核心事件怎么选、StandardReviewPolicy、引擎/调度器/SurfaceCoordinator 接线、recordSession 位置、从存量自研实现迁移的 key 映射、以及不许做的事（满意度过滤、pre-prompt UI、绕过标准策略自配阈值）。触发词：评分弹窗、评分引导、requestReview、SKStoreReviewController、rating prompt、review prompt、ReviewKit。
---

# Integrate ReviewKit

Use ReviewKit as the app's only eligibility and timing engine for
`requestReview()`. The Kit decides **whether** the app may ask and **when**
to fire the platform call. The host keeps the win-event name, app-specific
suppressors, the actual `requestReview()` / `AppStore.requestReview(in:)`,
cross-surface arbitration, and the settings-page write-review link.

⛔ Do not hand-write session/event/cooldown counters. ⛔ Do not add
SiriusRating or another third-party rating SDK.

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "0.1.0")
```

## Decide whether this app should adopt

Adopt only when **all** of these are true:

1. The product is an Apple app that will ship through the **App Store**.
2. It is in the house portfolio, **or** the owner explicitly asked this
   product to request ratings.
3. The repository already has (or is adding in the same change) an App Store
   surface: `fastlane/metadata/` or `app-store-metadata-manifest.json`.
   `review-kit-lint` treats anything else as "no App Store surface" and
   reports zero findings — that is not a license to skip the Kit on an app
   that is about to list.

Do **not** adopt when:

- the app is a client / commercial deliverable and the client has not asked
  for an App Store rating prompt;
- there is no App Store listing path (Developer ID, internal, TestFlight-only
  until a store record exists);
- the only "iOS" code is a companion inside a Web-classified commercial repo
  that cannot submit yet.

Thresholds live in `Sources/ReviewKit/StandardReviewPolicy.swift`. Changing a
number is a portfolio-wide decision in that file, not a per-app override.

## Read the local contract

Read this package `README.md` and the public declarations under
`Sources/ReviewKit/` before writing host code. Do not reconstruct API names
from memory. Doc comments on `ReviewRequestEngine` and
`ReviewRequestScheduler` are the authoritative platform semantics
(`requestReview()` has no "was shown" callback; cooldown stamps on attempt).

Also read and obey the target repository's `AGENTS.md` / `CLAUDE.md`. If the
host already has SurfaceCoordinatorKit, read
`integrate-surfacecoordinatorkit` before wiring the review candidate.

## Follow this workflow

1. Inventory what the Kit will replace: `SKStoreReviewController` /
   `requestReview()` call sites, hand-written session or "successful action"
   counters, last-prompt dates, per-version flags, pre-prompt UI ("Enjoying
   the app?"), and any "wait until paywall finished" gate that exists only
   for ratings. List every UserDefaults key before writing code.
2. Choose **one** core event name. It must be a completed value moment the
   user can repeat (saved a record, saved a pickup, saved an app). It must
   **not** be: process launch, first screen appear, opening settings, or the
   user tapping "Rate this app". Record it only after the write/save
   succeeded. If you cannot name that moment, stop — the product is not
   ready for a rating prompt.
3. Add the package (`https://github.com/Jewel591/ReviewKit`, up-to-next-major
   `from:` / Xcode "Up to Next Major Version") to the **application** target.
   Widgets and other extensions do not get this product. App / Xcode Cloud
   may commit `Package.resolved`; that does not replace a compatible range
   with an exact pin in the manifest.
4. Scoring prompts are app-initiated surfaces. If the host does not already
   have SurfaceCoordinatorKit, add it in the same change and follow
   `integrate-surfacecoordinatorkit`. `isEligible` only means "may be a
   candidate"; do not call `scheduleIfPossible` until review wins
   `arbitrate`. `review-kit-lint` names this in its requirements text but
   does not yet scan for `arbitrate` — passing the lint is not proof the
   coordinator is wired.
5. Construct one `ReviewKit.ReviewRequestEngine` with
   `StandardReviewPolicy.conditions(coreEvent:suppressors:)`. The
   module-qualified type name is the lint adoption evidence — an unqualified
   `ReviewRequestEngine(...)` is reported as not integrated. New apps use
   `ReviewPromptStorageKeys(namespace: "reviewPrompt")` (or the default
   `reviewKit` namespace). Do not hand-assemble the standard gates.
6. Host suppressors are allowed. The house convention after a marketing /
   launch-paywall / promo surface is a **2-hour** `QuietPeriodCondition`
   (not 24 hours). Add other `CustomReviewCondition`s only for states the
   app already owns (crash-last-launch, onboarding, auth merge). Do not
   invent suppressors the product does not have.
7. Call `recordSession()` **exactly once per process start**, in the app
   initializer or the same `startProcess()` that begins the surface session.
   A session is one process start, not one foregrounding. ⛔ Do not call it
   from `scenePhase` changes or `onAppear`.
8. Call `recordSignificantEvent("<coreEvent>")` only on the success path of
   that one win. Do not record on failure, undo, or duplicate-skipped saves
   unless the product already treats that path as a completed win.
9. Wire scheduling at **every** natural trigger: `onChange(of: isEligible,
   initial: true)`, root `onAppear` / process start, blocking state clearing,
   and the next core event. A scheduling round that exhausts retries does
   **not** consume eligibility; a single `onChange` leaves restored pending
   state stranded. `initial: true` is load-bearing because a pending flag
   restored across launch never produces a false→true edge.
10. Add the settings-page fallback with `AppStoreReviewLink.writeReviewURL
    (appID:)`. The system prompt may never appear. This link is
    user-initiated — it must **not** go through `arbitrate` or
    `recordRequested()`.
11. Delete the replaced in-house manager, counters, and pre-prompt UI in the
    same change. Two eligibility engines are worse than either alone.
12. Add the smallest host tests that prove: legacy keys (if any) are read by
    the new engine; `recordSession` cannot run twice per process; the core
    event is recorded only on the success path. Inject a dedicated
    `UserDefaults(suiteName:)` and a fixed clock into the engine; never test
    against `.standard` or real time. Kit-level behavior is already covered
    in this package — do not re-test `StandardReviewPolicy` in the app.
13. Run `review-kit-lint` (product-playbook). It checks the SPM range, a
    production `import ReviewKit`, module-qualified
    `ReviewKit.ReviewRequestEngine(...)`, and
    `StandardReviewPolicy.conditions(...)`. It does not check session
    placement, coordinator arbitration, extra trigger points, or the
    settings link. Passing the lint is necessary, not sufficient.

## Host wiring (load-bearing)

```swift
@MainActor
enum ReviewPrompt {
    static let coreEvent = "recordSaved" // this app's win; change the name
    static let appStoreID = "<numeric App Store ID>"

    static let engine = ReviewKit.ReviewRequestEngine(
        conditions: StandardReviewPolicy.conditions(
            coreEvent: coreEvent,
            suppressors: [
                QuietPeriodCondition(
                    identifier: "quietPeriod(marketingPrompt)",
                    quietInterval: 2 * 3600,
                    lastEventDate: { MarketingPrompts.lastShownDate }
                ),
            ]
        ),
        keys: ReviewPromptStorageKeys(namespace: "reviewPrompt"),
        onEvent: { event in Logger.review.info("\(String(describing: event))") }
    )
    static let scheduler = ReviewRequestScheduler()
}
```

SwiftUI — do not schedule from `onChange` until review wins arbitration.
`arbitrate` is side-effect free; call it again in `shouldRequest` and in
`request`. A 1.5s delay is long enough for update / What's New / promo to
become a better candidate.

```swift
@Environment(\.requestReview) private var requestReview

.onChange(of: ReviewPrompt.engine.isEligible, initial: true) { _, eligible in
    guard eligible else { return }
    scheduleReviewIfPossible()
}

private func scheduleReviewIfPossible() {
    guard surfaceRuntime.arbitrateReviewIfEligible() else { return }
    ReviewPrompt.scheduler.scheduleIfPossible(
        shouldRequest: {
            ReviewPrompt.engine.isEligible
                && surfaceRuntime.arbitrateReviewIfEligible()
        },
        isBlocked: { scenePhase != .active || hostIsBlockingReview },
        canRequestNow: { ReviewPrompt.engine.canRequestNow() },
        request: {
            // Re-check after the 1.5s delay: update / What's New / promo
            // may have become a higher-priority candidate while we waited.
            guard surfaceRuntime.arbitrateReviewIfEligible() else { return }
            requestReview()
            ReviewPrompt.engine.recordRequested()
            surfaceRuntime.recordReviewPresented()
        }
    )
}
```

When an *observable* blocking state appears, `scheduler.cancel()` and
re-schedule with fresh closures when it clears. Scheduler closures capture
values at schedule time; `@Environment` inside a captured closure does not
track later updates. A stale retry can burn the cooldown while the scene is
inactive.

UIKit has no `scenePhase` / `.requestReview`. Use `windowScene`,
`presentedViewController`, and `AppStore.requestReview(in:)`. Re-arbitrate
**inside** `request` — a higher-priority candidate may appear during the
1.5s delay. On root swap: `scheduler.cancel()`, clear only this scene's
suppression signals, then re-OR-aggregate. ⛔ Do not call
`clearAllSignals()` for a single-scene `swapRoot`. A dying host
(`view.window == nil`) only clears signals; do not treat that as "blocking
cleared" and `scheduleIfPossible`.

```swift
func scheduleReviewIfPossible(host: UIViewController) {
    let host = host.tabBarController ?? host
    ReviewPrompt.scheduler.scheduleIfPossible(
        shouldRequest: { ReviewPrompt.engine.isEligible },
        isBlocked: {
            let scene = host.view.window?.windowScene
            if scene?.activationState != .foregroundActive { return true }
            return coordinator.isSignalActive("user-sheet-visible")
                || coordinator.isSignalActive("settings-visible")
                || coordinator.isSignalActive("paywall-visible")
                || coordinator.isSignalActive("app-surface-visible")
        },
        hasBlockingPresentation: { host.presentedViewController != nil },
        canRequestNow: { ReviewPrompt.engine.canRequestNow() },
        request: {
            guard coordinator.arbitrate([reviewCandidate]).winner?.id == reviewCandidate.id,
                  let scene = host.view.window?.windowScene
            else { return }
            AppStore.requestReview(in: scene)
            ReviewPrompt.engine.recordRequested()
            coordinator.recordOutcome(.presented, for: reviewCandidate)
        }
    )
}
```

Settings fallback (user-initiated, no arbitration):

```swift
if let url = AppStoreReviewLink.writeReviewURL(appID: ReviewPrompt.appStoreID) {
    Link("Rate this app", destination: url)
}
```

## Migrating a shipped in-house implementation

Storage keys are the upgrade contract: existing users must keep session
counts, event totals, first-launch date, cooldown, and pending eligibility.
Map `ReviewPromptStorageKeys` onto the historical keys. If the old code had
a single undifferentiated action counter, alias both `significantEventKey`
and `significantEventTotal` onto that key — the engine will not double-count
when those two resolve to the same string.

`Tests/ReviewKitTests/StorageKeyMigrationTests.swift` only covers the
**permanent single-counter alias**. Copy that pattern when the app will keep
recording one event name.

⚠️ Aliasing is only sound with one significant event going forward. A second
event name would inflate the same counter. Multiple named events need a
one-time copy into distinct keys **before the first new-engine init**, then
construct `ReviewPromptStorageKeys` without the alias. There is no kit test
for this path — write it in the host:

```swift
let legacyTotal = defaults.integer(forKey: "reviewPrompt_successfulActionCount")
if defaults.object(forKey: "reviewPrompt_significantEvent_recordSaved") == nil {
    defaults.set(legacyTotal, forKey: "reviewPrompt_significantEvent_recordSaved")
    defaults.set(legacyTotal, forKey: "reviewPrompt_significantEventTotal")
}
```

The host PR must include a test that a pre-kit UserDefaults fixture is read
correctly by the new engine.

## Preserve these boundaries

- The engine answers "allowed to ask?"; the scheduler answers "fire now?".
  Neither renders UI nor imports StoreKit.
- Satisfaction routing (unhappy → feedback) belongs to the host or a support
  module. It may *call* ReviewKit; ReviewKit must not grow a satisfaction
  filter. "Only happy users see the prompt" violates App Store Guideline
  5.6.1 in spirit.
- ⛔ No pre-prompt UI ("Enjoying this app?").
- ⛔ No per-app threshold knobs and no hand-built standard-gate array.
  Genuinely divergent products assemble their own conditions under their own
  policy name — that is a product decision, not a silent fork.
- `requestReview()` has no "was shown" callback. `recordRequested()` stamps
  cooldown on **attempt**. Do not "fix" ignored system prompts by retrying
  in the same version.
- System hard cap: at most 3 displays per 365 days. Keep attempts rare;
  hang them after the win, never on launch or on the settings-button path.
- Kits do not depend on AppContextKit. If the host already uses
  `AppIdentity.current().marketingVersion`, passing it as `currentVersion`
  is optional host wiring, not a ReviewKit requirement.

## Review the result

Before declaring the integration complete:

- [ ] `recordSession()` cannot run more than once per process and is not on
      `onAppear` / `scenePhase`
- [ ] the core event is recorded only after a successful win, under one name
- [ ] every natural trigger calls `scheduleIfPossible`; `onChange` uses
      `initial: true`
- [ ] review loses to (or waits behind) other app-initiated surfaces via
      `arbitrate`; settings "Rate this app" does not
- [ ] observable blockers cancel the in-flight scheduler
- [ ] settings write-review link uses the real numeric App Store ID
- [ ] old counters / `ReviewPromptManager` / pre-prompt UI are deleted
- [ ] shipped users keep historical keys (or this is a new app with a
      namespaced default)
- [ ] `review-kit-lint` is clean, and the checklist above is not "lint passed
      so we are done"
