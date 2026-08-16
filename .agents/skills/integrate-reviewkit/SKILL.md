---
name: integrate-reviewkit
description: 在自家 App 矩阵中接入或调整 App Store 评分请求（requestReview 弹窗时机）时必须先加载：一律使用自研公开包 ReviewKit（github.com/Jewel591/ReviewKit）而不是手写计数器或引入第三方评分库。覆盖 StandardReviewPolicy 标准策略、引擎/调度器接线模式、从存量自研实现迁移的 key 映射、以及不许做的事（满意度过滤、pre-prompt UI、绕过标准策略自配阈值）。触发词：评分弹窗、评分引导、requestReview、SKStoreReviewController、rating prompt、review prompt、ReviewKit。
---

# ReviewKit：App Store 评分请求统一接入

所有自家 App 的评分请求策略走同一个包：**[Jewel591/ReviewKit](https://github.com/Jewel591/ReviewKit)**（公开 SPM 包，Xcode Cloud 可直接解析）。⛔ 不要手写计数器/UserDefaults 逻辑，不要引入 SiriusRating 等第三方库。

```swift
.package(url: "https://github.com/Jewel591/ReviewKit.git", from: "0.1.0")
```

## 标准接线（新 App）

App 只提供两样：核心事件名 + App 特有抑制条件。阈值不许自配——`StandardReviewPolicy` 是全矩阵统一策略（装机 ≥7 天、启动 ≥5 次、核心事件 ≥10 次、冷却 120 天、每版本一次）。要改数值就改包里的 `StandardReviewPolicy`（这是全矩阵决策），不要在某个 App 里绕开预设手拼条件数组。

```swift
@MainActor
enum ReviewPrompt {
    static let engine = ReviewRequestEngine(
        conditions: StandardReviewPolicy.conditions(
            coreEvent: "recordSaved",   // 本 App 的核心价值动作
            suppressors: [
                // 崩溃后不弹、付费墙可见不弹、刚提交反馈不弹……
                CustomReviewCondition(identifier: "noRecentCrash") { _ in
                    !CrashState.crashedLastLaunch
                },
                QuietPeriodCondition(
                    identifier: "quietPeriod(marketingPrompt)",
                    quietInterval: 24 * 3600,
                    lastEventDate: { MarketingPrompts.lastShownDate }
                ),
            ]
        ),
        keys: ReviewPromptStorageKeys(namespace: "reviewPrompt"),
        onEvent: { Analytics.track($0) }   // becameEligible / blocked / requestRecorded
    )
    static let scheduler = ReviewRequestScheduler()
}
```

视图层接线（两个 load-bearing 点都不能省）：

```swift
@Environment(\.requestReview) private var requestReview

// ⚠️ initial: true 必须写：pending 会跨启动持久化恢复，恢复出来的
// isEligible 没有 false→true 转变，默认 onChange 永远不会触发。
.onChange(of: ReviewPrompt.engine.isEligible, initial: true) { _, eligible in
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

⚠️ 调度轮重试耗尽**不消耗资格**，所以每个自然触发点（view appear、阻塞态解除、下一次核心事件）都要再调一次 `scheduleIfPossible`——它在途幂等、无 pending 时开销为零；只接一处 `onChange` 会让放弃的那轮永远搁浅。信号采集：冷启动一次 `recordSession()`；核心动作处 `recordSignificantEvent("recordSaved")`。

设置页固定加"给我们评分"入口（系统弹窗可能永远不出现）：

```swift
if let url = AppStoreReviewLink.writeReviewURL(appID: "<数字 App ID>") {
    Link("Rate this app", destination: url)
}
```

## 从存量自研实现迁移

存储 key 是升级契约：老用户的计数与冷却不许清零。用 `ReviewPromptStorageKeys` 的自定义 init 把每个 key 映射到历史 key；旧实现只有单一行为计数器时，把 `significantEventKey` 闭包和 `significantEventTotal` 都别名到那个旧 key（引擎对该映射已防双倍计数）。⚠️ 永久别名只适用于「迁移后只记录一个 significant event」的 App——别名之下任何命名事件都会灌进同一个计数器，会虚高核心事件计数；要用多个命名事件就做一次性搬迁（旧值迁入独立 key 后弃用别名）。参照包内 `StorageKeyMigrationTests` 的完整示例。迁移 PR 必须带一条"老 key 数据被新引擎正确读取"的测试。

## 平台语义（接入方必须知道）

- `requestReview()` **没有「已展示」回调**；引擎按「尝试」记冷却，系统没弹也烧预算——这是有意设计，别"修"。
- 系统硬顶：每 365 天最多展示 3 次。所以调用点要少而准（核心价值时刻之后），不要挂在启动或用户主动操作的响应里。
- SwiftUI 宿主注意：调度器闭包捕获的是调度时刻的值；可观察阻塞态出现时 `scheduler.cancel()`，解除后用新闭包重新调度。

## 红线

- ⛔ 不做满意度过滤（"只让满意用户看到评分弹窗"违反 App Store 审核指南 5.6.1 精神）。满意度分流（不满意 → 反馈通道）属于宿主/支持模块，它调用 ReviewKit，不反向。
- ⛔ 不加任何 pre-prompt UI（"喜欢这个 App 吗？"自绘弹窗）。
- ⛔ 不在单个 App 里自配阈值绕开 `StandardReviewPolicy`。
