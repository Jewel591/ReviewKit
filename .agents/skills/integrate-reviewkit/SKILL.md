---
name: integrate-reviewkit
description: 在自家 App 矩阵中接入或调整 App Store 评分请求（requestReview 弹窗时机）时必须先加载：一律使用自研公开包 ReviewKit（github.com/Jewel591/ReviewKit）而不是手写计数器或引入第三方评分库。覆盖何时接入/不接入、怎么选「用户最满意」的请求时机（offer(source:)）、reviewRequestHost 与 SurfaceCoordinator 接线、perform 的正确写法、埋点、从 0.x 迁移，以及不许做的事（统一累计门槛、满意度过滤、pre-prompt UI、启动时补弹）。触发词：评分弹窗、评分引导、requestReview、SKStoreReviewController、rating prompt、review prompt、ReviewKit。
---

# Integrate ReviewKit

Use ReviewKit 1.x as the app's only path to `requestReview()`. The **app**
decides which moments are worth asking at and calls `offer(source:)` there.
The **Kit** keeps attempts rare (fixed throttles), waits for a quiet moment,
and makes the platform call through a single exit. The host keeps the moment
choice and any app-specific "not now" rule, cross-surface arbitration inside
`perform`, analytics, and the settings-page write-review link.

⛔ Do not hand-write cooldown counters or pending flags. ⛔ Do not add
SiriusRating or another third-party rating SDK.

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "1.0.0")
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

## Read the local contract

Read this package `README.md` and the public declarations under
`Sources/ReviewKit/` before writing host code. Do not reconstruct API names
from memory. Doc comments on `ReviewRequestEngine`, `ReviewRequestPolicy`
and `reviewRequestHost` are the authoritative platform semantics.

Also read and obey the target repository's `AGENTS.md` / `CLAUDE.md`. If the
host has SurfaceCoordinatorKit, read `integrate-surfacecoordinatorkit` before
writing `perform`.

## Choose the moments (the product decision)

Apple shows the prompt at most 3 times per 365 days. Every attempt should land
when the user is most satisfied, so the question is never "how many users can
we reach" but "where is this user happiest".

A good moment:

- is a **final success** the user just achieved: a purchase whose
  entitlement is active, a record saved, a project exported;
- happens **after** the success UI settles (the host blocks during sheets,
  celebrations and transitions; see below);
- is not a launch, a first screen, a settings visit, an error recovery, or a
  payment still in progress.

Name each moment as a `ReviewRequestSource` — a short stable `snake_case`
string such as `purchase` or `record_milestone`. It keys that source's
cooldown and is the analytics `source` value; never rename a shipped one.

Typical choices:

- `purchase`: offer in the purchase **success** branch only (not cancelled,
  pending, not-entitled, failed, or restore). Optionally require the user to
  have used the product at least once — a first-launch purchase has not
  experienced value yet; another moment can catch them later.
- a usage milestone: count successes with `recordSignificantEvent`, then
  offer once the count reaches the app's threshold (e.g. `>= 3`). Use `>=`,
  not `==`: an offer that was blocked at the third success can be served at
  the fourth, and the source cooldown keeps it to once a year.
- Count **one user action once**: a batch that saves several records (AI
  import, multi-select duplicate) is one success, not N. Count only after the
  write committed, never on a failed or cancelled save.

Throttles are fixed in `ReviewRequestPolicy` (14 days between any two
attempts, 365 days per source, 180-second opportunity lifetime). They are not
per-app knobs.

## Follow this workflow

1. Inventory what the Kit will replace: `SKStoreReviewController` /
   `requestReview()` call sites, hand-written counters, last-prompt dates,
   per-version flags, pre-prompt UI, and any "wait until paywall finished"
   gate that exists only for ratings. List every UserDefaults key first.
2. Choose the moments (above). If you cannot name one, stop — the product is
   not ready for a rating prompt.
3. Add the package (up-to-next-major `from: "1.0.0"`) to the **application**
   target only. App / Xcode Cloud may commit `Package.resolved`.
4. Construct one `ReviewKit.ReviewRequestEngine` (module-qualified; that is
   the lint adoption evidence). New apps use
   `ReviewPromptStorageKeys(namespace: "reviewPrompt")` or the default.
5. Write one host function per moment that calls `engine.offer(source:)`,
   and route every call site of that moment through it. App-specific "not
   now" rules live in that function as plain code (the Kit has no condition
   types). House convention: skip non-purchase moments within **2 hours**
   after a marketing / launch-paywall / promo surface; do not apply it to
   `purchase` when that paywall itself is where purchases complete.
6. Call those host functions on the final-success paths.
7. Install `.reviewRequestHost(engine:isBlocked:hasBlockingPresentation:perform:)`
   **once**, at the scene root. A non-active `scenePhase` is already handled
   by the Kit. Get the two blocking inputs right (next section).
8. Write `perform` correctly (next section).
9. Send the analytics attempt event from the `.requestRecorded(source:)`
   callback in `onEvent` — the single exit — never from call sites.
10. Add the settings-page fallback with `AppStoreReviewLink.writeReviewURL
    (appID:)`. It is user-initiated: no arbitration, no `offer`.
11. Delete the replaced in-house manager, counters and pre-prompt UI in the
    same change.
12. Add host tests (see the boundary below) and run `review-kit-lint`.

## Feed the blockers correctly (load-bearing)

The host re-schedules only when `isBlocked` **changes value**, and a running
round reads the value captured when it was scheduled. So:

- `isBlocked` must be built from **observable** state (`@Observable` /
  `@State` / environment): lock screen, app-level sheet queue, surface
  coordinator activity, launch checks (launch paywall, update check),
  onboarding. A computed property that reads a plain singleton field or
  `UserDefaults` never re-renders, so the host never learns the block
  cleared and the opportunity expires silently.
- State the host cannot observe (a UIKit `presentedViewController`, a
  third-party overlay) goes into `hasBlockingPresentation`, which is
  evaluated live at every attempt.
- **Success overlays must report themselves.** A purchase celebration,
  confetti or "done" animation that plays right after the win is exactly
  where the prompt would land. Give the overlay an observable activity flag
  set in its own `onAppear` / `onDisappear` (keyed per instance, so two
  windows cannot clear each other) and OR it into `isBlocked`.
- Block during UI tests, screenshot automation and demo runs, so automated
  runs never call `requestReview()`.
- Offering before dismissing the paywall is fine: the sheet blocks the host,
  and the 1.5-second initial delay lets the next overlay appear before the
  first attempt.

## Write `perform` correctly (load-bearing)

`perform` runs on the main actor at the moment the Kit decided to serve the
opportunity. It must either call the platform API **synchronously** and
return `true`, or return `false` without calling it.

```swift
@Environment(\.requestReview) private var requestReview

content.reviewRequestHost(
    engine: ReviewPrompt.engine,
    isBlocked: isBlockingReviewPrompt,
    hasBlockingPresentation: { hasPresentedUIKitController }
) {
    // SurfaceCoordinatorKit 1.x: an unobservable surface; the coordinator
    // decides whether this moment may interrupt, and runs the call if so.
    surfaceRuntime.requestReviewIfAllowed { requestReview() }
}
```

- Return the arbiter's answer. `false` keeps the opportunity; the Kit retries
  until its deadline. Only `true` stamps cooldowns.
- ⛔ Do not call `engine` bookkeeping yourself — there is no
  `recordRequested()` in 1.x. A host helper that used to call it must drop
  that line.
- ⛔ Do not report the attempt to SurfaceCoordinator as `.presented`.
  `requestReview()` has no "was shown" callback; recording presented spends
  the session interruption budget and can hide a later What's New or promo.
- ⛔ Do not start a `Task` and return `true` before the call happened.

UIKit hosts (no `.requestReview` environment) may stay on 0.x until a UIKit
host API exists, or drive `ReviewRequestScheduler.scheduleIfPossible(engine:
isBlocked:hasBlockingPresentation:perform:)` directly with
`AppStore.requestReview(in:)` inside `perform`, cancelling and re-scheduling
on observable blocking changes.

## Verify on device

- Builds run from Xcode (development) show a test prompt on every request, so
  you can see when a moment fires. It never submits a rating.
- TestFlight builds never show the prompt; the request is a no-op.
- App Store builds give the app no signal. Judge the rollout by the attempt
  event and App Store Connect ratings, not by "I didn't see it".
- To re-test a moment, delete the app (or clear the namespace keys); the
  365-day source cooldown is otherwise working as designed.

## Analytics

Report attempts, not outcomes:

```swift
onEvent: { event in
    if case .requestRecorded(let source) = event {
        Analytics.capture("review_request_attempted", ["source": source.rawValue])
    }
}
```

Name and describe the event as an **attempt**. The app cannot know whether
the prompt appeared or a rating was submitted; check ratings in App Store
Connect. Register the event contract under the repository's analytics
policy.

## Migrating from 0.x

1.0 removes `StandardReviewPolicy`, the condition types
(`ReviewRequestCondition`, `QuietPeriodCondition`, `CustomReviewCondition`,
`ReviewRequestContext`), `recordSession()`, the per-version gate,
`isEligible` and the persisted pending flag. A 0.x quiet-period suppressor
becomes a plain check in the host's offer function. Migration contract:

- Keep the success counter and last request date keys
  (`significantEventTotal`, `significantEventKey`, `lastRequestDate`). A
  single-counter alias (both mapped onto one legacy key) remains safe; the
  engine does not double count.
- Map `legacyPendingRequest` onto the old pending key. The engine writes
  `false` on init; it never replays a stale pending request. No launch-time
  catch-up offer.
- Session count, first-launch date and last-request-version keys are no
  longer read. Leave them; do not migrate them anywhere.
- Source history starts empty. Do not attribute the old request to a source.
- Existing users who already passed a usage milestone get their opportunity
  at their next real success, not at launch.
- Delete the old scheduler wiring (`onChange(of: isEligible)`, manual
  `scheduleIfPossible` calls, cancel-on-block handlers) — the host modifier
  owns it.

Write a host test with the app's real legacy key fixture: init produces no
opportunity, the counter is preserved, and the old request date still holds
the 14-day gap.

## Preserve these boundaries

- ⛔ No unified eligibility thresholds (install age, sessions, N successes)
  added back in the Kit or copied into hosts as a gate before every offer.
  A milestone is fine when it *is* the chosen moment.
- ⛔ No launch-time offers, no settings-button offers, no offers before a
  payment completes.
- ⛔ No pre-prompt UI ("Enjoying this app?"), no satisfaction filter. "Only
  happy users see the prompt" violates App Store Guideline 5.6.1 in spirit.
- ⛔ No compensating retries for prompts the system did not show.
- Kits do not depend on SurfaceCoordinatorKit or AppContextKit; arbitration
  lives in the host's `perform`.

## Review the result

- [ ] every `offer(source:)` sits on a final-success path, not launch,
      settings, failure or an in-progress payment
- [ ] each moment's call sites go through one host function
- [ ] `.reviewRequestHost` is installed once at the scene root, and
      `isBlocked` covers app sheets, launch checks and success overlays
- [ ] every input of `isBlocked` is observable; unobservable presentation
      state is in `hasBlockingPresentation`
- [ ] a batch success counts once, and only after the write committed
- [ ] UI tests / screenshot automation are blocked
- [ ] `perform` returns the arbiter's answer, calls the platform API
      synchronously, and never records `.presented`
- [ ] the attempt event is sent only from `.requestRecorded(source:)`
- [ ] legacy keys are mapped and the pending key is never replayed
- [ ] settings write-review link uses the real numeric App Store ID
- [ ] old manager / scheduler wiring / pre-prompt UI are deleted
- [ ] `review-kit-lint` is clean, and this checklist is not "lint passed so
      we are done"

## Host test boundary

- Keep tests for: each moment offers only on its success path (and not on
  cancel/failure), milestone counting, the real legacy key fixture, the
  analytics mapping, and app-specific blockers.
- Throttles, deadlines, cancel/re-schedule and the single request exit are
  ReviewKit contracts. Do not re-test them in every app.
- Do not read `project.pbxproj`, scan imports/source strings, or assert old
  type-file absence in XCTest; structural checks belong to `review-kit-lint`.
- Give each moment function defaulted parameters for the engine and anything
  it reads (`UserDefaults`, now), and build the test engine through the same
  factory the app uses, so tests exercise the real keys and analytics
  mapping on an isolated suite.
- Use isolated `UserDefaults`, fixed time and public APIs. Never invoke the
  real StoreKit review prompt in tests.
