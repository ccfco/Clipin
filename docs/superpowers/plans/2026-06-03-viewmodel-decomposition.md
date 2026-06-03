# ClipboardViewModel 自洽状态机抽离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 ClipboardViewModel(1297 行)里 5 个不参与 SwiftUI 渲染拓扑的自洽状态机抽成独立单元,VM 保持唯一 ObservableObject 门面,语义与 view 订阅零改动。

**Architecture:** 方案 A(见 spec)。新增 5 个文件平铺到 `Clipin/ViewModels/`:`ClipSectionBuilder`(纯函数)、`LauncherNoticeCenter` / `LauncherLoadingCoordinator` / `PendingDeletionController`(@MainActor 状态机,回调投影到 VM @Published)、`BrowsePageLoader`(struct,持 core+settings)。VM 持有它们并转调。

**Tech Stack:** Swift 6 / SwiftUI / XCTest;Rust 不动。每步用 `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test` 验证。

**全局约束(每个 Task 都成立):**
- view 层 0 改动:`git diff` 不得含 `Clipin/Views/` 或 `Clipin/App/`。
- VM 上所有 `@Published`(名字/语义/可见性)保持不变,仅其「内部由谁驱动」改变。
- 先补单测(对当前行为编写、立即通过)→ 再抽离 + VM 转调 → 全测试绿 → 提交。
- 现有 `ClipinTests/ClipboardViewModelTests.swift` + `ActionPaletteShortcutTests.swift` 全程必须绿。
- 测试 target 新文件需进 `ClipinTests`;源文件进 `Clipin`。xcodegen 按目录递归纳入,新增 `.swift` 文件 `xcodegen generate` 后自动进 target——每个 Task 加新文件后先跑 `xcodegen generate` 再 `xcodebuild test`。

---

## Task 1: ClipSectionBuilder(纯函数)

**Files:**
- Create: `Clipin/ViewModels/ClipSectionBuilder.swift`
- Create: `ClipinTests/ClipSectionBuilderTests.swift`
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`(删 `dateFormatter`+`makeDateSections`,改 `rebuildSections`)

- [ ] **Step 1: 写测试**

`ClipinTests/ClipSectionBuilderTests.swift`:

```swift
import XCTest
@testable import Clipin

final class ClipSectionBuilderTests: XCTestCase {
    private func item(id: String, createdAt: Int64, isPinned: Bool = false) -> ClipListItem {
        ClipListItem(
            id: id, preview: id, clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: isPinned, createdAt: createdAt, imagePath: nil, attachmentPaths: nil,
            charCount: 0, pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil
        )
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testGroupsTodayYesterdayAndOlder() {
        let cal = Calendar.current
        let now = Date()
        let today = item(id: "t", createdAt: ms(now))
        let yesterday = item(id: "y", createdAt: ms(cal.date(byAdding: .day, value: -1, to: now)!))
        let older = item(id: "o", createdAt: ms(cal.date(byAdding: .day, value: -10, to: now)!))

        let sections = ClipSectionBuilder.build(items: [today, yesterday, older], showPinnedSection: false)

        XCTAssertEqual(sections.first?.title, NSLocalizedString("Today", comment: ""))
        XCTAssertEqual(sections.first?.items.map(\.id), ["t"])
        XCTAssertEqual(sections.dropFirst().first?.title, NSLocalizedString("Yesterday", comment: ""))
        XCTAssertEqual(sections.flatMap(\.items).count, 3)
    }

    func testPinnedSectionHoistedFirst() {
        let now = ms(Date())
        let pinned = item(id: "p", createdAt: now, isPinned: true)
        let regular = item(id: "r", createdAt: now)

        let sections = ClipSectionBuilder.build(items: [pinned, regular], showPinnedSection: true)

        XCTAssertEqual(sections.first?.title, NSLocalizedString("Pinned", comment: ""))
        XCTAssertEqual(sections.first?.items.map(\.id), ["p"])
        // 非 pinned 落到日期组
        XCTAssertTrue(sections.dropFirst().flatMap(\.items).map(\.id).contains("r"))
    }

    func testPinnedSectionSuppressedWhenFlagOff() {
        let now = ms(Date())
        let pinned = item(id: "p", createdAt: now, isPinned: true)
        let sections = ClipSectionBuilder.build(items: [pinned], showPinnedSection: false)
        XCTAssertNotEqual(sections.first?.title, NSLocalizedString("Pinned", comment: ""))
        XCTAssertEqual(sections.flatMap(\.items).map(\.id), ["p"])
    }

    func testEmptyInputYieldsNoSections() {
        XCTAssertTrue(ClipSectionBuilder.build(items: [], showPinnedSection: true).isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -20
```
Expected: 编译失败 `cannot find 'ClipSectionBuilder' in scope`。

- [ ] **Step 3: 建 ClipSectionBuilder,搬实现**

`Clipin/ViewModels/ClipSectionBuilder.swift`(逻辑逐字搬自 VM 现有 `makeDateSections` L1261-1296 + `dateFormatter` L1131-1136 + `rebuildSections` 的 pinned 拼装 L1138-1150):

```swift
import Foundation

/// items → 分组 sections 的纯函数收口。从 ClipboardViewModel 抽出:不持有状态、
/// 不参与渲染拓扑,只按「Pinned / Today / Yesterday / 本地化月日」分组。
/// flatOrder / shortcutOrder 等渲染派生态留在 VM。
enum ClipSectionBuilder {
    /// showPinnedSection=true:先析出 isPinned 项成 Pinned 组,其余按日期分组。
    static func build(items: [ClipListItem], showPinnedSection: Bool) -> [ClipSection] {
        guard showPinnedSection else {
            return makeDateSections(from: items)
        }
        let pinnedItems = items.filter(\.isPinned)
        let regularItems = items.filter { !$0.isPinned }
        var result: [ClipSection] = []
        if !pinnedItems.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Pinned", comment: ""), items: pinnedItems))
        }
        result.append(contentsOf: makeDateSections(from: regularItems))
        return result
    }

    /// section 标题用的简短月日格式。locale 自适应让 macOS 按当前 locale 选 month/day 排序
    /// (en: "May 20", zh: "5月20日"),避免硬编码 "M月d日" 在英文环境也显中文。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    private static func makeDateSections(from items: [ClipListItem]) -> [ClipSection] {
        let calendar = Calendar.current
        var today: [ClipListItem] = []
        var yesterday: [ClipListItem] = []
        var older: [(key: String, items: [ClipListItem])] = []
        var olderMap: [String: Int] = [:]

        for item in items {
            let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)
            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else {
                let key = dateFormatter.string(from: date)
                if let idx = olderMap[key] {
                    older[idx].items.append(item)
                } else {
                    olderMap[key] = older.count
                    older.append((key: key, items: [item]))
                }
            }
        }

        var result: [ClipSection] = []
        if !today.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Today", comment: ""), items: today))
        }
        if !yesterday.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Yesterday", comment: ""), items: yesterday))
        }
        for group in older {
            result.append(ClipSection(title: group.key, items: group.items))
        }
        return result
    }
}
```

`ClipSection` 结构保留在 ClipboardViewModel.swift 顶部不动(builder 同 module 引用)。

- [ ] **Step 4: 改 VM rebuildSections,删搬走的代码**

VM 中删除 `private static let dateFormatter`(L1131-1136)和 `private static func makeDateSections`(L1261-1296)。`rebuildSections` 改为:

```swift
private func rebuildSections() {
    sections = ClipSectionBuilder.build(items: items, showPinnedSection: shouldShowPinnedSection)
    flatOrder = sections.flatMap(\.items)
    shortcutOrder = flatOrder
    shortcutIndexByID = Dictionary(
        uniqueKeysWithValues: shortcutOrder.prefix(9).enumerated().map { ($1.id, $0 + 1) }
    )
}
```

- [ ] **Step 5: 跑全测试确认绿**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`,含新 `ClipSectionBuilderTests` 4 个。

- [ ] **Step 6: 提交**

```bash
git add Clipin/ViewModels/ClipSectionBuilder.swift ClipinTests/ClipSectionBuilderTests.swift Clipin/ViewModels/ClipboardViewModel.swift project.yml Clipin.xcodeproj 2>/dev/null; git add -A
git commit -m "$(cat <<'EOF'
refactor: 抽 ClipSectionBuilder 纯函数,VM 日期分组收口

【改动范围】新增 ClipSectionBuilder(build/makeDateSections/dateFormatter),
VM rebuildSections 转调;flatOrder/shortcutOrder 派生留 VM。补 4 个纯函数单测。
EOF
)"
```

---

## Task 2: LauncherNoticeCenter

**Files:**
- Create: `Clipin/ViewModels/LauncherNoticeCenter.swift`
- Create: `ClipinTests/LauncherNoticeCenterTests.swift`
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`(删 `noticeTask`/`noticeAction`,`showNotice`/`performNoticeAction`/`dismissNotice` 转调)

- [ ] **Step 1: 写测试**

`ClipinTests/LauncherNoticeCenterTests.swift`:

```swift
import XCTest
@testable import Clipin

@MainActor
final class LauncherNoticeCenterTests: XCTestCase {
    func testShowEmitsNoticeThroughCallback() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("hello", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        XCTAssertEqual(last?.text, "hello")
        XCTAssertEqual(last?.style, .info)
    }

    func testDismissEmitsNil() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("hello", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        center.dismiss()
        XCTAssertNil(last)
    }

    func testPerformActionRunsActionThenClears() {
        var fired = 0
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("u", style: .warning, actionTitle: "Undo", duration: .seconds(99)) { fired += 1 }
        center.performAction()
        XCTAssertEqual(fired, 1)
        XCTAssertNil(last, "performAction 后 notice 应清空")
    }

    func testPerformActionWithoutActionJustClears() {
        var last: LauncherNotice?
        let center = LauncherNoticeCenter { last = $0 }
        center.show("x", style: .info, actionTitle: nil, duration: .seconds(99), action: nil)
        center.performAction()  // 无 action,不崩
        XCTAssertNil(last)
    }
}
```

`LauncherNoticeStyle` 需可比较——它当前是无 raw value 的 enum,默认不 Equatable。`testShowEmitsNoticeThroughCallback` 用到 `last?.style == .info`。若编译报不 Equatable,给该 enum 加 `: Equatable`(纯加 protocol,无行为变化),并在本步同时改 `Clipin/ViewModels/ClipboardViewModel.swift` 的 `enum LauncherNoticeStyle` 声明。

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -20
```
Expected: `cannot find 'LauncherNoticeCenter' in scope`。

- [ ] **Step 3: 建 LauncherNoticeCenter**

`Clipin/ViewModels/LauncherNoticeCenter.swift`(逻辑搬自 VM `showNotice` L1003-1018 / `performNoticeAction` L1020-1024 / `dismissNotice` L1026-1031):

```swift
import Foundation

/// launcher 一次性提示的队列状态机。从 ClipboardViewModel 抽出:持有自动消失 task 与
/// 可选 action,通过 onChange 把「当前 notice / nil」投影到 VM 的 @Published launcherNotice。
@MainActor
final class LauncherNoticeCenter {
    private let onChange: (LauncherNotice?) -> Void
    private var task: Task<Void, Never>?
    private var action: (() -> Void)?

    init(onChange: @escaping (LauncherNotice?) -> Void) {
        self.onChange = onChange
    }

    func show(_ text: String,
              style: LauncherNoticeStyle,
              actionTitle: String?,
              duration: Duration,
              action: (() -> Void)?) {
        onChange(LauncherNotice(text: text, style: style, actionTitle: actionTitle))
        self.action = action
        task?.cancel()
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func performAction() {
        let action = self.action
        dismiss()
        action?()
    }

    func dismiss() {
        task?.cancel()
        task = nil
        action = nil
        onChange(nil)
    }
}
```

- [ ] **Step 4: VM 转调**

VM 中:
- 删字段 `private var noticeTask: Task<Void, Never>?`(L228)、`private var noticeAction: (() -> Void)?`(L229)。
- 新增 lazy 单元(放在 `core`/`settings` 字段附近):
  ```swift
  private lazy var noticeCenter = LauncherNoticeCenter { [weak self] notice in
      self?.launcherNotice = notice
  }
  ```
- `@Published private(set) var launcherNotice: LauncherNotice?`(L74)保留。
- `showNotice` 保留对外签名与默认参数,改为转调(替换 L1003-1018 整个函数体):
  ```swift
  func showNotice(
      _ text: String,
      style: LauncherNoticeStyle = .info,
      actionTitle: String? = nil,
      duration: Duration = .seconds(3),
      action: (() -> Void)? = nil
  ) {
      noticeCenter.show(text, style: style, actionTitle: actionTitle, duration: duration, action: action)
  }
  ```
- `performNoticeAction`(L1020-1024)→ `{ noticeCenter.performAction() }`;`dismissNotice`(L1026-1031)→ `{ noticeCenter.dismiss() }`。

- [ ] **Step 5: 跑全测试确认绿**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`。`ClipboardViewModelTests.testDeleteCanBeUndone...`(依赖 notice action)必须仍绿。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: 抽 LauncherNoticeCenter,VM notice 队列收口

【改动范围】新增 LauncherNoticeCenter(show/performAction/dismiss + 自动消失 task),
VM showNotice/performNoticeAction/dismissNotice 转调,launcherNotice 经 onChange 投影。
LauncherNoticeStyle 加 Equatable 供测试断言。补 4 个状态机单测。
EOF
)"
```

---

## Task 3: LauncherLoadingCoordinator

**Files:**
- Create: `Clipin/ViewModels/LauncherLoadingCoordinator.swift`
- Create: `ClipinTests/LauncherLoadingCoordinatorTests.swift`
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`

- [ ] **Step 1: 写测试**

`ClipinTests/LauncherLoadingCoordinatorTests.swift`:

```swift
import XCTest
@testable import Clipin

@MainActor
final class LauncherLoadingCoordinatorTests: XCTestCase {
    func testReferenceCountingKeepsVisibleUntilAllSourcesCleared() {
        var visible = false
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { visible = $0 }
        c.set(true, source: .previewNetwork("a"))
        XCTAssertTrue(visible)
        c.set(true, source: .previewNetwork("b"))
        c.set(false, source: .previewNetwork("a"))
        XCTAssertTrue(visible, "仍有 b 占用,不该熄灭")
    }

    func testClearImmediatelyHides() {
        var visible = false
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { visible = $0 }
        c.set(true, source: .quickLookPreparation)
        XCTAssertTrue(visible)
        c.clear()
        XCTAssertFalse(visible, "clear 同步熄灭,不走最小可见时长")
    }

    func testOnVisibleChangeFiresOnlyOnFlip() {
        var changes: [Bool] = []
        let c = LauncherLoadingCoordinator(minimumVisibleSeconds: 0) { changes.append($0) }
        c.set(true, source: .previewNetwork("a"))   // → true
        c.set(true, source: .previewNetwork("b"))   // 已 true,不再回调
        XCTAssertEqual(changes, [true])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -20
```
Expected: `cannot find 'LauncherLoadingCoordinator' in scope`。

- [ ] **Step 3: 建 LauncherLoadingCoordinator**

`Clipin/ViewModels/LauncherLoadingCoordinator.swift`(逻辑搬自 VM `LauncherLoadingSource` L264-267 / `setLauncherLoading` L463-479 / `clearLauncherLoading` L481-489 / `scheduleLauncherLoadingHide` L491-506):

```swift
import Foundation

/// 顶部流光(isLauncherLoading)的引用计数 + 防闪烁状态机。从 ClipboardViewModel 抽出。
/// 多个慢异步源(网络预览 / Quick Look 准备)各占一个 Source;点亮即记时间,熄灭走
/// minimumVisibleSeconds 最小可见时长防一闪而过。可见性翻转时经 onVisibleChange 投影到
/// VM @Published isLauncherLoading。注意:本地 SQLite getItem 这类瞬时操作绝不入此集合。
@MainActor
final class LauncherLoadingCoordinator {
    enum Source: Hashable {
        case quickLookPreparation
        case previewNetwork(String)
    }

    private let minimumVisibleSeconds: TimeInterval
    private let onVisibleChange: (Bool) -> Void
    private var sources: Set<Source> = []
    private var becameVisibleAt: Date?
    private var hideTask: Task<Void, Never>?
    private var isVisible = false

    init(minimumVisibleSeconds: TimeInterval, onVisibleChange: @escaping (Bool) -> Void) {
        self.minimumVisibleSeconds = minimumVisibleSeconds
        self.onVisibleChange = onVisibleChange
    }

    func set(_ isLoading: Bool, source: Source) {
        if isLoading {
            sources.insert(source)
        } else {
            sources.remove(source)
        }
        if sources.isEmpty {
            scheduleHide()
        } else {
            hideTask?.cancel()
            hideTask = nil
            if !isVisible {
                becameVisibleAt = Date()
                setVisible(true)
            }
        }
    }

    func clear() {
        hideTask?.cancel()
        hideTask = nil
        sources.removeAll()
        if isVisible { setVisible(false) }
        becameVisibleAt = nil
    }

    private func setVisible(_ value: Bool) {
        isVisible = value
        onVisibleChange(value)
    }

    private func scheduleHide() {
        guard isVisible else { return }
        let visibleAt = becameVisibleAt ?? Date()
        let elapsed = Date().timeIntervalSince(visibleAt)
        let remaining = max(0, minimumVisibleSeconds - elapsed)
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, self.sources.isEmpty else { return }
            self.setVisible(false)
            self.becameVisibleAt = nil
            self.hideTask = nil
        }
    }
}
```

- [ ] **Step 4: VM 转调**

VM 中:
- 删 `enum LauncherLoadingSource`(L264-267)、字段 `launcherLoadingSources`(L223)/`launcherLoadingBecameVisibleAt`(L224)/`launcherLoadingHideTask`(L225)、常量 `launcherLoadingMinimumVisibleSeconds`(L242)、方法 `setLauncherLoading`(L463-479)/`clearLauncherLoading`(L481-489)/`scheduleLauncherLoadingHide`(L491-506)。
- `@Published private(set) var isLauncherLoading = false`(L76)保留。
- 新增 lazy:
  ```swift
  private lazy var loadingCoordinator = LauncherLoadingCoordinator(minimumVisibleSeconds: 0.65) { [weak self] visible in
      self?.isLauncherLoading = visible
  }
  ```
- 调用点改写(把 `LauncherLoadingSource` → `LauncherLoadingCoordinator.Source`):
  - `setPreviewNetworkLoading`(L459-461):`loadingCoordinator.set(isLoading, source: .previewNetwork(key))`。
  - `selectItem` 内 `clearLauncherLoading()`(L389)→ `loadingCoordinator.clear()`。
  - `previewSelected` 内 `setLauncherLoading(true, source: .quickLookPreparation)`(L819)→ `loadingCoordinator.set(true, source: .quickLookPreparation)`;落定后 `setLauncherLoading(false, source: .quickLookPreparation)`(L852)同理。
  - `cancelPreviewPreparation`(L862-867)内 `setLauncherLoading(false, source: .quickLookPreparation)`→ `loadingCoordinator.set(false, source: .quickLookPreparation)`。

- [ ] **Step 5: 跑全测试确认绿**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`。现有 `testLauncherLoadingTracksCurrentPreviewNetworkRequest` / `testSelectingItemDoesNotShowLauncherLoadingForLocalRead` 必须仍绿(端到端验证引用计数 + 最小可见时长)。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: 抽 LauncherLoadingCoordinator,顶部流光状态机收口

【改动范围】新增 LauncherLoadingCoordinator(Source 引用计数 + 最小可见时长防闪烁),
VM setPreviewNetworkLoading/previewSelected/selectItem/cancelPreviewPreparation 转调,
isLauncherLoading 经 onVisibleChange 投影。补 3 个引用计数/翻转单测。
EOF
)"
```

---

## Task 4: PendingDeletionController

**Files:**
- Create: `Clipin/ViewModels/PendingDeletionController.swift`
- Create: `ClipinTests/PendingDeletionControllerTests.swift`
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`

- [ ] **Step 1: 写测试**

`ClipinTests/PendingDeletionControllerTests.swift`:

```swift
import XCTest
@testable import Clipin

@MainActor
final class PendingDeletionControllerTests: XCTestCase {
    func testArmSetsPendingID() {
        let c = PendingDeletionController(window: .seconds(7))
        c.arm(id: "a") { }
        XCTAssertEqual(c.pendingID, "a")
    }

    func testCommitNowRunsCommitOnceAndClears() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.commitNow()
        XCTAssertEqual(count, 1)
        XCTAssertNil(c.pendingID)
        c.commitNow()  // 已无 pending,不重复
        XCTAssertEqual(count, 1)
    }

    func testCommitOtherCommitsWhenDifferent() {
        let c = PendingDeletionController(window: .seconds(7))
        var committed: [String] = []
        c.arm(id: "a") { committed.append("a") }
        c.commitOther(than: "b")
        XCTAssertEqual(committed, ["a"])
        XCTAssertNil(c.pendingID)
    }

    func testCommitOtherSkipsWhenSame() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.commitOther(than: "a")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(c.pendingID, "a")
    }

    func testCancelDoesNotCommit() {
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.cancel()
        XCTAssertEqual(count, 0)
        XCTAssertNil(c.pendingID)
    }

    func testReArmCommitsNothingAutomatically() {
        // arm 新 id 不隐式 commit 旧 pending(清旧由调用方显式 commitOther 负责)
        let c = PendingDeletionController(window: .seconds(7))
        var count = 0
        c.arm(id: "a") { count += 1 }
        c.arm(id: "b") { count += 1 }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(c.pendingID, "b")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -20
```
Expected: `cannot find 'PendingDeletionController' in scope`。

- [ ] **Step 3: 建 PendingDeletionController**

`Clipin/ViewModels/PendingDeletionController.swift`:

```swift
import Foundation

/// 7s 可撤销删除的「pending id + 倒计时 task」状态机。从 ClipboardViewModel 抽出。
/// 删库副作用不进本类——由调用方在 arm 时注入 commit closure,本类只管何时执行它。
@MainActor
final class PendingDeletionController {
    private(set) var pendingID: String?
    private let window: Duration
    private var task: Task<Void, Never>?
    private var pendingCommit: (() -> Void)?

    init(window: Duration) {
        self.window = window
    }

    /// 置 pending=id 并起 window 倒计时,到点执行 commit。只做 set+timer,
    /// 不隐式处理旧 pending(清旧由调用方显式 commitOther(than:))。
    func arm(id: String, commit: @escaping () -> Void) {
        pendingID = id
        pendingCommit = commit
        task?.cancel()
        let window = self.window
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: window) } catch { return }
            guard let self, self.pendingID == id else { return }
            self.runCommit()
        }
    }

    /// 立即提交当前 pending(若有)。用于 finalize / 退出前收尾。
    func commitNow() {
        guard pendingID != nil else { return }
        task?.cancel()
        runCommit()
    }

    /// 若存在 pending 且 != id,立即提交它(删除新条目前清旧 pending)。
    func commitOther(than id: String) {
        guard let pid = pendingID, pid != id else { return }
        commitNow()
    }

    /// 撤销:取消倒计时、清 pending,不执行 commit。
    func cancel() {
        task?.cancel()
        task = nil
        pendingID = nil
        pendingCommit = nil
    }

    private func runCommit() {
        let commit = pendingCommit
        task = nil
        pendingID = nil
        pendingCommit = nil
        commit?()
    }
}
```

- [ ] **Step 4: VM 转调**

VM 中:
- 删 `struct PendingDeletion`(L232-234)、字段 `pendingDeletion`(L236)/`pendingDeletionTask`(L237)、方法 `commitPendingDeletionBeforeReplacing`(L1232-1236)/`commitPendingDeletion`(L1238-1249)。
- 新增 let(init 内,不需回调 self):
  ```swift
  private let pendingDeletionController = PendingDeletionController(window: .seconds(7))
  ```
- 新增私有删库执行(替代旧 `commitPendingDeletion` 的副作用部分):
  ```swift
  private func commitDeletion(id: String) {
      do {
          try core.deleteItem(id: id)
          NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
      } catch {
          showNotice(error.localizedDescription, style: .error)
      }
      loadItems()
  }
  ```
- `deleteItem`(L951-995)改写:把 `commitPendingDeletionBeforeReplacing(with: id)` → `pendingDeletionController.commitOther(than: id)`;把 `pendingDeletion = PendingDeletion(id: id)` + 末尾 `pendingDeletionTask = Task {...}` 两段合并为:
  ```swift
  pendingDeletionController.arm(id: id) { [weak self] in
      self?.commitDeletion(id: id)
  }
  ```
  (`loadItems()` 与 `showNotice(...undo...)` 调用保持原位、原顺序不变。)
- `finalizePendingDeletion`(L997-1001)→
  ```swift
  func finalizePendingDeletion() {
      pendingDeletionController.commitNow()
  }
  ```
- `undoPendingDeletion`(L1251-1259)改为:
  ```swift
  private func undoPendingDeletion(id: String) {
      guard pendingDeletionController.pendingID == id else { return }
      pendingDeletionController.cancel()
      loadItems()
      selectItem(id: id)
      showNotice(NSLocalizedString("Deletion undone.", comment: ""), style: .success)
  }
  ```
- `visibleItems`(L1159-1173)里 `guard let pendingDeletion else { return filtered }` / `pendingDeletion.id` → 用 `pendingDeletionController.pendingID`:
  ```swift
  guard let pendingID = pendingDeletionController.pendingID else { return filtered }
  return filtered.filter { $0.id != pendingID }
  ```

- [ ] **Step 5: 跑全测试确认绿**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`。`testDeleteCanBeUndoneBeforePendingDeletionCommits` / `testFinalizePendingDeletionRemovesItemFromStorage` 必须仍绿。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: 抽 PendingDeletionController,可撤销删除状态机收口

【改动范围】新增 PendingDeletionController(arm/commitNow/commitOther/cancel + 倒计时 task),
删库副作用由 VM 注入 commitDeletion closure;VM deleteItem/finalize/undo/visibleItems 转调
controller.pendingID。补 6 个状态转移单测。
EOF
)"
```

---

## Task 5: BrowsePageLoader

**Files:**
- Create: `Clipin/ViewModels/BrowsePageLoader.swift`
- Create: `ClipinTests/BrowsePageLoaderTests.swift`
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`

- [ ] **Step 1: 写测试**

`ClipinTests/BrowsePageLoaderTests.swift`:

```swift
import XCTest
@testable import Clipin

@MainActor
final class BrowsePageLoaderTests: XCTestCase {
    private var tempRoots: [URL] = []
    override func tearDown() {
        for root in tempRoots { try? FileManager.default.removeItem(at: root) }
        tempRoots.removeAll()
        super.tearDown()
    }
    private func makeCore() throws -> ClipinCore {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowsePageLoaderTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)
        return try ClipinCore(dbPath: rootURL.appendingPathComponent("test.db").path, imageDir: imageURL.path)
    }
    private func loader() throws -> BrowsePageLoader {
        BrowsePageLoader(core: try makeCore(), settings: .shared)
    }

    func testEffectiveTypeFilterBrowseMode() throws {
        let l = try loader()
        XCTAssertNil(l.effectiveTypeFilter(query: "", browseMode: .all))
        XCTAssertEqual(l.effectiveTypeFilter(query: "", browseMode: .text), .text)
        XCTAssertEqual(l.effectiveTypeFilter(query: "", browseMode: .image), .image)
        XCTAssertNil(l.effectiveTypeFilter(query: "", browseMode: .pinned))
    }

    func testEffectiveTypeFilterSearchModeDropsPinned() throws {
        let l = try loader()
        // 搜索态:pinned 降级为无类型过滤,其余类型仍生效
        XCTAssertNil(l.effectiveTypeFilter(query: "x", browseMode: .pinned))
        XCTAssertEqual(l.effectiveTypeFilter(query: "x", browseMode: .url), .url)
    }

    func testVisibleSearchReturnsAllRegardlessOfPinned() throws {
        let l = try loader()
        let pinned = ClipListItem(id: "p", preview: "p", clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: true, createdAt: 1, imagePath: nil, attachmentPaths: nil, charCount: 0,
            pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil)
        let regular = ClipListItem(id: "r", preview: "r", clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: false, createdAt: 1, imagePath: nil, attachmentPaths: nil, charCount: 0,
            pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil)
        let out = l.visible([pinned, regular], query: "abc", browseMode: .all, excludingID: nil)
        XCTAssertEqual(out.map(\.id), ["p", "r"], "搜索是全局召回,pinned 展示策略不参与过滤")
    }

    func testVisibleExcludesPendingDeletionID() throws {
        let l = try loader()
        let a = ClipListItem(id: "a", preview: "a", clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: false, createdAt: 1, imagePath: nil, attachmentPaths: nil, charCount: 0,
            pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil)
        let b = ClipListItem(id: "b", preview: "b", clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: false, createdAt: 1, imagePath: nil, attachmentPaths: nil, charCount: 0,
            pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil)
        let out = l.visible([a, b], query: "x", browseMode: .all, excludingID: "a")
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testFetchPagePinnedReturnsOnlyPinned() throws {
        let core = try makeCore()
        _ = try core.importItem(content: "pin", clipType: .text, sourceApp: nil, sourceName: nil,
            imagePath: nil, isPinned: true, createdAt: 2_000, alias: nil)
        _ = try core.importItem(content: "reg", clipType: .text, sourceApp: nil, sourceName: nil,
            imagePath: nil, isPinned: false, createdAt: 1_000, alias: nil)
        let l = BrowsePageLoader(core: core, settings: .shared)
        let page = try l.fetchPage(offset: 0, pageSize: 50, query: "", browseMode: .pinned, excludingID: nil)
        XCTAssertEqual(page.items.map(\.preview), ["pin"])
        XCTAssertFalse(page.hasMore)
    }
}
```

注:`.shared` 的 `pinnedItemsPresentation` 默认非 `.pinnedOnlyView`,以上 `visible`/`fetchPage` 用例不受其影响(搜索态 / pinned 浏览态都绕过该策略)。pinnedOnlyView 端到端行为已由 `ClipboardViewModelTests.testPinnedOnlyPresentation...` 覆盖,本处不重复。

- [ ] **Step 2: 跑测试确认失败**

```bash
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -20
```
Expected: `cannot find 'BrowsePageLoader' in scope`。

- [ ] **Step 3: 建 BrowsePageLoader**

`Clipin/ViewModels/BrowsePageLoader.swift`(逻辑搬自 VM `effectiveTypeFilter` L1175-1180 / `shouldShowPinnedSection` L1182-1185 / `usesUnpinnedBrowseQuery` L1228-1230 / `visibleItems` L1159-1173(去掉 pending 过滤,改 excludingID 参数)/ `fetchBrowsePage` L1193-1226(改 throws)):

```swift
import Foundation

/// 浏览/搜索的分页取数 + 可见性过滤收口。从 ClipboardViewModel 抽出:
/// 按 query/browseMode 选 core API、算 typeFilter、按 pinned 展示策略过滤。
/// fetchPage throws(UI notice 副作用收回 VM catch),不内部吞成空。
struct BrowsePageLoader {
    let core: ClipinCore
    let settings: SettingsStore

    struct Page {
        let items: [ClipListItem]
        let rawCount: Int
        let hasMore: Bool
    }

    func effectiveTypeFilter(query: String, browseMode: LauncherBrowseMode) -> ClipType? {
        if query.isEmpty {
            return browseMode.typeFilter
        }
        return browseMode.isPinnedOnly ? nil : browseMode.typeFilter
    }

    func shouldShowPinnedSection(query: String, browseMode: LauncherBrowseMode) -> Bool {
        guard query.isEmpty, !browseMode.isPinnedOnly else { return false }
        return settings.pinnedItemsPresentation == .topSection
    }

    /// 搜索全局召回不过滤;浏览态按 pinned 展示策略过滤;末了剔除 excludingID(pending 删除)。
    func visible(_ items: [ClipListItem],
                 query: String,
                 browseMode: LauncherBrowseMode,
                 excludingID: String?) -> [ClipListItem] {
        let filtered: [ClipListItem]
        if !query.isEmpty {
            filtered = items
        } else if browseMode.isPinnedOnly {
            filtered = items.filter(\.isPinned)
        } else if settings.pinnedItemsPresentation == .pinnedOnlyView {
            filtered = items.filter { !$0.isPinned }
        } else {
            filtered = items
        }
        guard let excludingID else { return filtered }
        return filtered.filter { $0.id != excludingID }
    }

    /// 按 mode 选 core API 取一页,内部已做 visible 过滤。失败抛出由 VM catch。
    func fetchPage(offset: Int,
                   pageSize: Int,
                   query: String,
                   browseMode: LauncherBrowseMode,
                   excludingID: String?) throws -> Page {
        let chunk: [ClipListItem]
        if browseMode.isPinnedOnly {
            chunk = try core.getPinnedListItems(
                limit: Int32(pageSize), offset: Int32(offset),
                typeFilter: effectiveTypeFilter(query: query, browseMode: browseMode))
        } else if settings.pinnedItemsPresentation == .pinnedOnlyView {
            chunk = try core.getUnpinnedListItems(
                limit: Int32(pageSize), offset: Int32(offset),
                typeFilter: effectiveTypeFilter(query: query, browseMode: browseMode))
        } else {
            chunk = try core.getListItems(
                limit: Int32(pageSize), offset: Int32(offset),
                typeFilter: effectiveTypeFilter(query: query, browseMode: browseMode))
        }
        return Page(
            items: visible(chunk, query: query, browseMode: browseMode, excludingID: excludingID),
            rawCount: chunk.count,
            hasMore: chunk.count == pageSize
        )
    }
}
```

注:`fetchBrowsePage` 原本调用前已算好 `typeFilter` 传入;此处 `fetchPage` 内部按 `query`/`browseMode` 自算 `effectiveTypeFilter`,与原 `fetchBrowsePage(offset:typeFilter:)` 的入参在浏览态(`loadItems` 用 `effectiveTypeFilter`)等价。

- [ ] **Step 4: VM 转调**

VM 中:
- 删方法 `effectiveTypeFilter`(L1175-1180,改为 computed 调 loader)、`shouldShowPinnedSection`(L1182-1185)、`usesUnpinnedBrowseQuery`(L1228-1230)、`visibleItems`(L1159-1173)、`fetchBrowsePage`(L1193-1226)。
- 新增 let(init 内):
  ```swift
  private let browsePageLoader: BrowsePageLoader
  ```
  init 里 `self.browsePageLoader = BrowsePageLoader(core: core, settings: settings)`(在 `self.core`/`self.settings` 之后)。
- 替换内部引用:
  - `rebuildSections` 里 `shouldShowPinnedSection` → `browsePageLoader.shouldShowPinnedSection(query: searchQuery, browseMode: browseMode)`。
  - `loadItems`(L305-343)浏览分支:
    ```swift
    if searchQuery.isEmpty {
        do {
            let page = try browsePageLoader.fetchPage(
                offset: 0, pageSize: Self.pageSize,
                query: searchQuery, browseMode: browseMode,
                excludingID: pendingDeletionController.pendingID)
            items = page.items
            totalLoadedFromDB = page.rawCount
            hasMore = page.hasMore
        } catch {
            ClipinLog.viewModel.error("fetchPage failed: \(error.localizedDescription, privacy: .public)")
            items = []
            totalLoadedFromDB = 0
            hasMore = false
            showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
        }
    } else {
        // 搜索分支不变(已有 try/catch)
        ...
        // 末尾 items = visibleItems(...) → items = browsePageLoader.visible(items, query: searchQuery, browseMode: browseMode, excludingID: pendingDeletionController.pendingID)
    }
    ```
    原 L332 `items = visibleItems(from: items)`(搜索分支后统一调)→ 注意:原代码搜索分支 `items` 已是搜索结果,浏览分支 `items` 是 `page.items`(已 visible 过滤)。原 L332 对两分支都再跑一次 `visibleItems`。**为保持等价**:把 `loadItems` 末尾的统一 `items = visibleItems(from: items)` 删除,改为仅搜索分支内对结果调 `browsePageLoader.visible(...)`(浏览分支 page.items 已过滤,不重复)。等价性:浏览分支原本 `fetchBrowsePage` 内 visible 一次 + L332 再 visible 一次(幂等);搜索分支原本 L332 visible 一次。改后浏览一次、搜索一次,语义等价(visible 幂等)。
  - `loadMoreItems`(L346-357):
    ```swift
    func loadMoreItems() {
        guard hasMore, searchQuery.isEmpty else { return }
        let page: BrowsePageLoader.Page
        do {
            page = try browsePageLoader.fetchPage(
                offset: totalLoadedFromDB, pageSize: Self.pageSize,
                query: searchQuery, browseMode: browseMode,
                excludingID: pendingDeletionController.pendingID)
        } catch {
            ClipinLog.viewModel.error("fetchPage(more) failed: \(error.localizedDescription, privacy: .public)")
            showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            hasMore = false
            return
        }
        guard !page.items.isEmpty || page.hasMore else { hasMore = false; return }
        items.append(contentsOf: page.items)
        totalLoadedFromDB += page.rawCount
        hasMore = page.hasMore
        rebuildSections()
    }
    ```

- [ ] **Step 5: 跑全测试确认绿**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`。`testPinnedOnlyPresentation...` / `testPinnedBrowseModeCanLoadMore...` 必须仍绿(分页语义)。

- [ ] **Step 6: 提交**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor: 抽 BrowsePageLoader,分页取数+可见性过滤收口

【改动范围】新增 BrowsePageLoader(fetchPage/visible/effectiveTypeFilter/
shouldShowPinnedSection);fetchPage 改 throws、UI notice 副作用收回 VM catch;
VM loadItems/loadMoreItems/rebuildSections 转调。补 5 个分页/过滤单测。
EOF
)"
```

---

## Task 6: 收尾(VM doc 注释 + 跨 target 验证 + Codex review)

**Files:**
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`(类顶部加门面分工注释)

- [ ] **Step 1: VM 顶部加门面职责注释**

在 `@MainActor final class ClipboardViewModel` 声明上方加:

```swift
/// launcher 的门面 ViewModel(唯一 ObservableObject)。自洽状态机已抽到独立单元,
/// 本类负责编排它们 + 持有 SwiftUI 渲染态(@Published、selectedItemRevision 判等信号、
/// shortcutIndexByID 等):
///   - ClipSectionBuilder        items → 分组 sections(纯函数)
///   - LauncherNoticeCenter      一次性提示队列 → @Published launcherNotice
///   - LauncherLoadingCoordinator 顶部流光引用计数防闪烁 → @Published isLauncherLoading
///   - PendingDeletionController  7s 可撤销删除 timer(删库副作用由本类注入)
///   - BrowsePageLoader          分页取数 + pinned 展示策略过滤
/// 渲染拓扑不可动:MainPanel @ObservedObject 全量订阅本类;PreviewPane 刻意不订阅、
/// 靠 selectedItemRevision 判等。改这些会重蹈导航卡顿。
```

- [ ] **Step 2: 跨 target 全量测试**

```bash
./scripts/build-rust.sh
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test 2>&1 | tail -10
```
Expected: `** TEST SUCCEEDED **`。

- [ ] **Step 3: 确认 view 层 0 改动**

```bash
git diff 6fe612d..HEAD --stat -- Clipin/Views/ Clipin/App/
```
Expected: 输出为空(view/App 层无任何改动)。若非空则违反 spec,需排查。

- [ ] **Step 4: VM 行数核对**

```bash
wc -l Clipin/ViewModels/ClipboardViewModel.swift Clipin/ViewModels/*.swift
```
Expected: VM ≤ ~700 行;5 个新单元各 < 120 行。

- [ ] **Step 5: Codex 子 agent review**

调用 codex:codex-rescue 子 agent review 整体 diff(`git diff 6fe612d..HEAD -- Clipin/ViewModels/`),重点:① VM 转调与原内联逻辑语义等价(尤其 deleteItem/undo/finalize 的 pending 状态转移、loadItems 双分支 visible 幂等性、loading 引用计数);② 注入 closure `[weak self]` 无循环引用;③ view 层 0 改动。

- [ ] **Step 6: 提交收尾**

```bash
git add -A
git commit -m "$(cat <<'EOF'
docs: ClipboardViewModel 门面职责 + 5 单元分工注释

【改动范围】VM 类顶部补门面注释(各单元分工 + 渲染拓扑不可动红线)。
完成自洽状态机抽离:VM 1297→约 N 行,5 单元独立可测,view 层 0 改动。
EOF
)"
```

---

## Self-Review(写计划后自查)

**Spec 覆盖:** 5 单元(ClipSectionBuilder/LauncherNoticeCenter/LauncherLoadingCoordinator/PendingDeletionController/BrowsePageLoader)各一 Task(1-5),收尾 Task 6 覆盖 VM doc 注释 + 跨 target 验证 + view 0 改动核对 + Codex review。spec「行为不变三道保证」分别落在:① Task 6 Step 3 git diff 核对;② 每 Task Step 1 先补单测;③ 每 Task Step 5 现有测试回归。✓

**类型一致性:** `LauncherLoadingCoordinator.Source`(.quickLookPreparation/.previewNetwork)、`PendingDeletionController`(arm/commitNow/commitOther/cancel/pendingID)、`BrowsePageLoader.Page`(items/rawCount/hasMore)+ 方法名(fetchPage/visible/effectiveTypeFilter/shouldShowPinnedSection)在 Task 内定义与 VM 转调处一致。`LauncherNoticeCenter.show` 全参数 vs VM `showNotice` 默认参数封装一致。✓

**Placeholder:** 无 TBD/TODO;每个新单元给完整实现;每个测试给完整代码;VM 改动给 before/after 片段 + 行号定位。✓

**潜在风险点(执行时注意):**
- 行号会随每个 Task 提交漂移——Task N 引用的 L 行号基于初始 1297 行版本,执行后续 Task 时按「逻辑位置 + 函数名」定位,不死认行号。
- `loadItems` 双分支 visible 幂等性是等价性关键(见 Task 5 Step 4 说明),Codex review 必查。
- lazy var(noticeCenter/loadingCoordinator)首次访问在 init 之后,self 已完全初始化,捕获 `[weak self]` 安全。
