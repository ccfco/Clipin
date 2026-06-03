# ClipboardViewModel 自洽状态机抽离设计

## 问题

`Clipin/ViewModels/ClipboardViewModel.swift` 是 1297 行的 SwiftUI 上帝对象,约 25 个 `@Published`、7 个内聚子系统挤在一个文件里。但它的复杂度**不均匀**:

- **大半行数是治导航卡顿的渲染优化耦合**——`EditingDraft` 独立 `ObservableObject`(打字不波及全列表)、`selectedItemRevision` 判等信号、`PreviewPane` 刻意不订阅 VM、`shortcutIndexByID` 预计算。这些是资产不是债,**拆错就重蹈卡顿**。
- **真正的债是若干自洽状态机被塞进同一文件**:日期分组、loading 防闪烁调度、7s 可撤销删除、notice 队列、分页取数。它们各自独立,却和渲染优化挤在一起,读者分不清「哪段动了会影响渲染、哪段不会」。

## 目标

把不参与 SwiftUI 渲染拓扑的自洽状态机抽成独立单元,各自可单测;VM 仍是唯一 `ObservableObject` 门面,把这些单元的输出投影到自己的 `@Published`。VM 从 1297 行降到约 650 行,**语义一字不改、view 订阅拓扑零改动**。

## 非目标

- 不拆成多个 `@Published` 子 store(方案 B)——嵌套 `ObservableObject` 不自动传播 `objectWillChange`,需 Combine 转发样板,且极易破坏 `PreviewPane` 不订阅 / revision 判等优化。
- 不动选中/预览编排、Palette 编排——它们是动作编排中心,强行切只会制造转发样板。
- 不动 view 层任何订阅(`MainPanel @ObservedObject`、`@EnvironmentObject`、`PreviewPane let vm`)。
- 不动 Rust 层。

## 方案

5 个单元平铺到 `Clipin/ViewModels/`,各独立文件。VM 持有它们。

### 1. ClipSectionBuilder(纯函数)

`Clipin/ViewModels/ClipSectionBuilder.swift`。吞掉当前 VM 的 `makeDateSections` + `dateFormatter`,以及 `rebuildSections` 里「pinned section + date section」的拼装。

```swift
enum ClipSectionBuilder {
    /// items → 分组后的 sections。showPinnedSection=true 时先析出 Pinned 组,
    /// 其余按 Today/Yesterday/<本地化月日> 分组。
    static func build(items: [ClipListItem], showPinnedSection: Bool) -> [ClipSection]
}
```

VM 的 `rebuildSections` 变为:

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

`flatOrder`/`shortcutOrder`/`shortcutIndexByID` 是 VM 私有渲染态,留在 VM。`dateFormatter`(静态、locale 自适应)随 `makeDateSections` 一并搬入 builder。

### 2. LauncherLoadingCoordinator(@MainActor class,非 ObservableObject)

`Clipin/ViewModels/LauncherLoadingCoordinator.swift`。吞掉 `launcherLoadingSources` / `launcherLoadingBecameVisibleAt` / `launcherLoadingHideTask` / `LauncherLoadingSource` 枚举 + `setLauncherLoading` / `clearLauncherLoading` / `scheduleLauncherLoadingHide` + `minimumVisibleSeconds` 常量。

```swift
@MainActor
final class LauncherLoadingCoordinator {
    enum Source: Hashable {
        case quickLookPreparation
        case previewNetwork(String)
    }
    /// onVisibleChange 在「可见性 bool 真正翻转」时回调,VM 在回调里设 @Published isLauncherLoading。
    init(minimumVisibleSeconds: TimeInterval, onVisibleChange: @escaping (Bool) -> Void)
    func set(_ isLoading: Bool, source: Source)
    func clear()
}
```

内部完整保留现状机:多 source 引用计数、点亮即记 `becameVisibleAt`、熄灭走 `minimumVisibleSeconds` 最小可见时长防闪烁。VM 保留 `@Published private(set) var isLauncherLoading = false`,在 `onVisibleChange` 里赋值。`setPreviewNetworkLoading` / `previewSelected` / `selectItem(clear)` 等调用点改为转调 coordinator。

### 3. LauncherNoticeCenter(@MainActor class,非 ObservableObject)

`Clipin/ViewModels/LauncherNoticeCenter.swift`。吞掉 `noticeTask` / `noticeAction` + `showNotice` / `performNoticeAction` / `dismissNotice`。

```swift
@MainActor
final class LauncherNoticeCenter {
    /// onChange 在 notice 出现/消失时回调,VM 投影到 @Published launcherNotice。
    init(onChange: @escaping (LauncherNotice?) -> Void)
    func show(_ text: String,
              style: LauncherNoticeStyle,
              actionTitle: String?,
              duration: Duration,
              action: (() -> Void)?)
    func performAction()
    func dismiss()
}
```

VM 保留 `@Published private(set) var launcherNotice`,并保留一层 `showNotice(...)` 薄封装(默认参数 style=.info/duration=.seconds(3))转调 center——全项目调用点不必改。

### 4. PendingDeletionController(@MainActor class)

`Clipin/ViewModels/PendingDeletionController.swift`。吞掉 `PendingDeletion` 结构、`pendingDeletion` / `pendingDeletionTask` + `commitPendingDeletionBeforeReplacing` / `commitPendingDeletion` / `undoPendingDeletion` 的 timer 生命周期。**删库副作用(core.delete + post notification + loadItems + 失败 notice)不进 controller**,由 VM 在 `arm` 时注入的 `commit` closure 执行。

```swift
@MainActor
final class PendingDeletionController {
    var pendingID: String? { get }                       // 供 BrowsePageLoader.visible 过滤
    init(window: Duration)
    /// 置 pending=id 并起 window 倒计时,到点执行 commit。只做「set pending + start timer」,
    /// 不隐式处理旧 pending——清旧 pending 由 VM 在 arm 前显式调 commitOther(than:)(还原现状控制流)。
    func arm(id: String, commit: @escaping () -> Void)
    /// 立即 commit 当前 pending(若有);用于 finalize / 退出前收尾。
    func commitNow()
    /// 若 pending 存在且 != id,立即 commit 它(用于删除新条目前清旧 pending)。
    func commitOther(than id: String)
    /// 撤销:取消倒计时、清 pending,不执行 commit。
    func cancel()
}
```

VM 的 `deleteItem` 保留全部编排(校验 getItem、算 nextSelection、设 selection、`showNotice` undo 7s、`loadItems`),只把「pending 状态 + timer」交给 controller;`commit` closure 内放 `core.deleteItem` + post `.clipHistoryDidChange` + `loadItems` + 失败 `showNotice`。`finalizePendingDeletion` → `controller.commitNow()`;`undoPendingDeletion` → `controller.cancel()` + VM 收尾(loadItems/select/notice)。

### 5. BrowsePageLoader(struct,持 core+settings)

`Clipin/ViewModels/BrowsePageLoader.swift`。吞掉 `fetchBrowsePage` / `visibleItems` / `effectiveTypeFilter` / `usesUnpinnedBrowseQuery` / `shouldShowPinnedSection`。

```swift
struct BrowsePageLoader {
    let core: ClipinCore
    let settings: SettingsStore
    struct Page { let items: [ClipListItem]; let rawCount: Int; let hasMore: Bool }

    /// 按 mode 选 core API(pinned / unpinned / all)取一页,内部已做 visible 过滤。
    /// 失败抛出(由 VM catch 后 showNotice)——不再内部吞成空+notice。
    func fetchPage(offset: Int, pageSize: Int,
                   query: String, browseMode: LauncherBrowseMode,
                   excludingID: String?) throws -> Page
    /// 搜索全局召回 / 浏览按 pinned 展示策略过滤,再剔除 excludingID(pending 删除)。
    func visible(_ items: [ClipListItem],
                 query: String, browseMode: LauncherBrowseMode,
                 excludingID: String?) -> [ClipListItem]
    func effectiveTypeFilter(query: String, browseMode: LauncherBrowseMode) -> ClipType?
    func shouldShowPinnedSection(query: String, browseMode: LauncherBrowseMode) -> Bool
}
```

**控制流唯一变化**:当前 `fetchBrowsePage` 在 catch 里 `showNotice` + 返回空;改为 `fetchPage` `throws`,VM 的 `loadItems` / `loadMoreItems` 两处 catch 后 `showNotice` + 退化空页。结果等价(空列表 + error notice),但把 UI 副作用收回 VM。`visible` 的 `excludingID` 由 VM 传 `pendingDeletionController.pendingID`。

## 行为不变保证(三道)

1. **view 订阅拓扑零改动**:`MainPanel` 仍 `@ObservedObject` 全量订阅 VM;`PreviewPane` 仍 `let vm`(不订阅)+ `selectedItemRevision` 判等;各 Preview 子 view `let vm`/`weak var vm` 调方法不变。所有 `@Published` 仍在 VM 上,名字/语义不变。
2. **先测后搬**:每个单元先补单测(对当前行为编写、立即通过),再做语义等价搬移。
3. **VM 行为回归网**:现有 `ClipinTests/ClipboardViewModelTests.swift` + `ActionPaletteShortcutTests.swift` 全程必须绿;`xcodebuild test` 跨 target 全绿。

## 测试策略

| 单元 | 新单测要点 |
|---|---|
| `ClipSectionBuilder` | Today/Yesterday/older 分组、pinned section 析出、空输入、跨日期边界(用固定 createdAt 毫秒时间戳构造) |
| `LauncherLoadingCoordinator` | 多 source 引用计数(set true×2 / false×1 仍可见)、clear 立即不可见、`onVisibleChange` 仅在 bool 翻转时触发 |
| `LauncherNoticeCenter` | show→onChange(非nil)、dismiss→onChange(nil)、performAction 触发注入 action 且随后清空 |
| `PendingDeletionController` | arm 后 pendingID==id、commitOther(than:) 对不同 id 立即 commit、cancel 不 commit、commitNow 执行一次 |
| `BrowsePageLoader` | `effectiveTypeFilter`/`shouldShowPinnedSection` 在搜索态 vs 浏览态、pinned vs 普通的取值;`visible` 的 pinned 展示策略 + excludingID 过滤(用真 core 插入已知数据) |

注:`LauncherLoadingCoordinator` 的最小可见时长涉及 `Task.sleep` 时序,单测只覆盖引用计数与即时翻转逻辑,时序调度部分由现有 VM 集成行为兜底,不强测。

## 实现步骤

每个单元一个原子提交,顺序为「补单测(绿)→ 抽离 + VM 改为转调(绿)」。建议顺序由独立到耦合:

1. `ClipSectionBuilder`(纯函数,零依赖,最先)
2. `LauncherNoticeCenter`
3. `LauncherLoadingCoordinator`
4. `PendingDeletionController`
5. `BrowsePageLoader`(耦合最高,最后)
6. 收尾:VM 顶部补一段「门面职责 + 5 单元分工」doc 注释;`xcodebuild test` 跨 target 全绿;Codex 子 agent review 整体 diff。

## 验收

- 每步 `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test` 全绿。
- VM 行数显著下降(目标 ≤ ~700),5 个单元各自 < 120 行、职责单一。
- view 层 0 改动(git diff 不含 `Clipin/Views/` `Clipin/App/`)。
- Codex 子 agent review 判定语义等价、无回归。

## 风险

- **PendingDeletionController 的 commit 注入闭包易循环引用**:闭包捕获 self 必须 `[weak self]`,与现状 `pendingDeletionTask` 的 `[weak self]` 一致。
- **BrowsePageLoader 改 throws 后两个调用点**:`loadItems`(搜索分支已 try/catch,浏览分支需补)+ `loadMoreItems` 都要正确 catch,否则浏览失败从「空+notice」变成崩溃。单测 + 现有 VM 测试兜底。
- **搬移过程中漏改某个调用点**:Swift 编译器会报未定义符号,不会静默错(与 storage 收口同理,编译期暴露)。
