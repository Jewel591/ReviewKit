import SwiftUI

extension View {
    /// Serves the engine's review opportunities from this view: observes
    /// offers, waits for a quiet moment, cancels while blocked, and never
    /// serves past an opportunity's deadline. Install once, at the root of the
    /// scene that should show the prompt.
    ///
    /// - Parameters:
    ///   - engine: the app's single ``ReviewRequestEngine``.
    ///   - isBlocked: the host's observable blocking state (lock screen, app
    ///     sheets, launch checks, success overlays...). A non-active
    ///     `scenePhase` is always treated as blocked; do not repeat it.
    ///   - hasBlockingPresentation: fallback for presentation state the host
    ///     cannot observe (e.g. a UIKit `presentedViewController`).
    ///   - perform: call the environment's `requestReview()` synchronously and
    ///     return `true`, or return `false` without calling it (e.g. the
    ///     app's surface arbiter refused). Do not start async work and return
    ///     `true`, and do not report the attempt to an arbiter as "presented":
    ///     the system may show nothing.
    public func reviewRequestHost(
        engine: ReviewRequestEngine,
        isBlocked: Bool,
        hasBlockingPresentation: @escaping @MainActor () -> Bool = { false },
        perform: @escaping @MainActor () -> Bool
    ) -> some View {
        modifier(
            ReviewRequestHostModifier(
                engine: engine,
                isBlocked: isBlocked,
                hasBlockingPresentation: hasBlockingPresentation,
                perform: perform
            )
        )
    }
}

private struct ReviewRequestHostModifier: ViewModifier {
    let engine: ReviewRequestEngine
    let isBlocked: Bool
    let hasBlockingPresentation: @MainActor () -> Bool
    let perform: @MainActor () -> Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var driver = ReviewRequestHostDriver()

    private var blocked: Bool {
        ReviewRequestHostDriver.isBlocked(hostBlocked: isBlocked, scenePhase: scenePhase)
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: engine.pendingOpportunity?.id, initial: true) { _, id in
                driver.opportunityChanged(id, request: request)
            }
            .onChange(of: blocked) { _, _ in
                driver.blockingChanged(request: request)
            }
    }

    private var request: ReviewRequestHostDriver.Request {
        ReviewRequestHostDriver.Request(
            engine: engine,
            isBlocked: blocked,
            hasBlockingPresentation: hasBlockingPresentation,
            perform: perform
        )
    }
}

/// The host modifier's decisions, kept out of the view so they can be tested
/// without rendering SwiftUI.
@MainActor
final class ReviewRequestHostDriver {
    struct Request {
        let engine: ReviewRequestEngine
        let isBlocked: Bool
        let hasBlockingPresentation: @MainActor () -> Bool
        let perform: @MainActor () -> Bool
    }

    private let scheduler: ReviewRequestScheduler

    init(scheduler: ReviewRequestScheduler = ReviewRequestScheduler()) {
        self.scheduler = scheduler
    }

    nonisolated static func isBlocked(hostBlocked: Bool, scenePhase: ScenePhase) -> Bool {
        hostBlocked || scenePhase != .active
    }

    /// A new opportunity appeared (or the host just installed). A blocked host
    /// schedules nothing; the round starts once the block clears.
    func opportunityChanged(_ id: UUID?, request: Request) {
        guard id != nil else { return }
        schedule(request)
    }

    /// Closures capture values at schedule time: drop the stale round and
    /// start a fresh one once the block clears. The opportunity's deadline is
    /// not extended by this.
    func blockingChanged(request: Request) {
        scheduler.cancel()
        if !request.isBlocked { schedule(request) }
    }

    private func schedule(_ request: Request) {
        let blocked = request.isBlocked
        scheduler.scheduleIfPossible(
            engine: request.engine,
            isBlocked: { blocked },
            hasBlockingPresentation: request.hasBlockingPresentation,
            perform: request.perform
        )
    }
}
