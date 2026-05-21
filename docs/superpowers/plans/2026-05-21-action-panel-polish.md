# ⌘K 动作面板动画与体验优化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Clipin 的 ⌘K 动作面板从右下角 ⌘K 按钮缩放展开/收回、盖住底栏，补上头部上下文、分组分隔线、最大高度+滚动与悬浮投影，并修掉面板开启时主列表/预览闪现滚动条的 bug。

**Architecture:** 纯 SwiftUI 前端改动，不涉及 Rust。入场/退场动画用一对新的弹簧 token，由 `ClipboardViewModel` 切换 `isShowingActions` 时的显式 `withAnimation` 驱动（区分 reveal/dismiss）；面板定位 padding 改为与底栏玻璃胶囊外接角重合，配合 `.bottomTrailing` 缩放锚点形成「从按钮长出」的观感。滚动条 bug 的根因是给「含 ScrollView 的视图」加了肉眼不可见的微缩放，触发 macOS overlay 滚动条因 bounds 变化而闪现——修复即删除这些微缩放与配套死代码。

**Tech Stack:** SwiftUI（macOS 26+）、AppKit、`xcodebuild` / `xcodegen`。本项目 Swift 端无单元测试框架，每个代码任务以「Xcode 编译通过」为自动化关卡，最后一个任务做 Release 构建 + 自截图视觉 QA。

**设计依据:** `docs/superpowers/specs/2026-05-21-action-panel-polish-design.md`

---

## 前置准备

执行任何任务前，确保构建环境就绪（`.xcodeproj` 是 xcodegen 生成、不入库）：

```bash
./scripts/build-rust.sh && xcodegen generate
```

**每个代码任务的编译验证命令**（统一用 Debug，比 Release 快）：

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5
```

预期结尾出现 `** BUILD SUCCEEDED **`。

---

## 文件结构

| 文件 | 职责 | 本计划中的角色 |
|---|---|---|
| `Clipin/App/ClipinTheme.swift` | 主题 token：动效、间距、scene state | 新增 2 个动效 token、新增 1 个尺寸常量、删除 4 个死 scene 属性 |
| `Clipin/Views/ClipListItem+Display.swift` | 列表条目展示派生属性（标题/图标） | **新建**：抽取主列表与面板头部共用的标题/图标推导 |
| `Clipin/Views/ClipItemRow.swift` | 主列表 row 视图 | 改用上面的扩展，删除内部重复推导 |
| `Clipin/Views/ActionPalette.swift` | ⌘K 动作面板视图 | 定位、头部上下文、分组分隔线、最大高度+滚动、悬浮投影 |
| `Clipin/Views/MainPanel.swift` | 主面板布局 + 面板/底栏挂载 | 入场/退场过渡、底栏淡出、删除含 ScrollView 视图的微缩放 |
| `Clipin/Views/PreviewPane.swift` | 右侧预览面板 | 删除 `previewScale` 微缩放 |
| `Clipin/ViewModels/ClipboardViewModel.swift` | 面板状态与动作 | `isShowingActions` 切换处包 `withAnimation` |

---

## Task 1: 新增动作面板动效 token

纯新增，不破坏任何现有代码，编译必然通过。

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`（`enum ClipinMotion`，约 62-71 行）

- [ ] **Step 1: 在 `ClipinMotion` 末尾新增两个弹簧 token**

把 `enum ClipinMotion` 中的这一段：

```swift
    static let statePulse = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let ambient = Animation.easeInOut(duration: 7.6)
    static let panel = commandReveal
}
```

改为：

```swift
    static let statePulse = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let ambient = Animation.easeInOut(duration: 7.6)
    static let panel = commandReveal
    /// ⌘K 动作面板入场：从右下角 ⌘K 按钮缩放展开，带一点生气、不过弹。
    static let paletteReveal = Animation.spring(response: 0.30, dampingFraction: 0.80)
    /// ⌘K 动作面板退场：向右下角快速收回，不回弹、收得干脆。
    static let paletteDismiss = Animation.spring(response: 0.20, dampingFraction: 0.92)
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 提交**

```bash
git add Clipin/App/ClipinTheme.swift
git commit -m "$(cat <<'EOF'
feat: 新增动作面板入场/退场动效 token

【根因/背景】⌘K 面板入场退场需要区分弹簧——入场带生气、退场收得快，
现有 commandReveal 单一 token 无法表达。
【改动范围】ClipinMotion 新增 paletteReveal / paletteDismiss 两个弹簧。
EOF
)"
```

---

## Task 2: 抽取 ClipListItem 展示标题与类型图标

面板头部要显示「类型图标 + 条目标题」，与主列表 row 必须一致。当前推导逻辑私有在 `ClipItemRow` 内。抽取成 `ClipListItem` 扩展，两处共用，避免文案漂移。

**Files:**
- Create: `Clipin/Views/ClipListItem+Display.swift`
- Modify: `Clipin/Views/ClipItemRow.swift`（`displayText` 约 440-454 行、`firstLineTruncated` 约 456-462 行、`iconName` 约 486-493 行）

- [ ] **Step 1: 新建扩展文件**

创建 `Clipin/Views/ClipListItem+Display.swift`，内容：

```swift
import Foundation

/// 列表条目的展示派生属性。主列表 row 与 ⌘K 动作面板头部共用同一套
/// 标题/图标推导，避免两处各算一遍导致文案漂移。
extension ClipListItem {
    /// 单行展示标题：文本/URL 取首行截断；图片有 OCR 取 OCR 文字、否则 "Image"；文件取文件标题。
    var displayTitle: String {
        switch clipType {
        case .text, .url:
            return Self.firstLineTruncated(preview) ?? "(empty)"
        case .image:
            // preview 经 SQL COALESCE：有 OCR 时为识别文字，否则为占位符 "image"。
            // 用 "image" 作为哨兵判断是否有可展示的 OCR 文字。
            if preview != "image", let line = Self.firstLineTruncated(preview) {
                return line
            }
            return NSLocalizedString("Image", comment: "")
        case .file:
            return FileClipboardContent.displayTitle(for: preview)
        }
    }

    /// 类型对应的通用 SF Symbol 名（与主列表 row 的类型图标一致）。
    var typeIconName: String {
        switch clipType {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .file:  return "folder"
        case .url:   return "link"
        }
    }

    /// 取文本首行，trim 后截断到 limit 字符；空内容返回 nil。
    private static func firstLineTruncated(_ text: String, limit: Int = 120) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
```

- [ ] **Step 2: `ClipItemRow` 的 `displayText` 改为转调扩展**

在 `Clipin/Views/ClipItemRow.swift` 中，把这一段（约 440-454 行）：

```swift
    private var displayText: String {
        switch item.clipType {
        case .text, .url:
            return firstLineTruncated(item.preview) ?? "(empty)"
        case .image:
            // preview 经 SQL COALESCE 处理：有 OCR 结果时为识别文字，否则为固定占位符 "image"
            // 用 "image" 作为哨兵判断是否有可展示的 OCR 文字
            if item.preview != "image", let line = firstLineTruncated(item.preview) {
                return line
            }
            return NSLocalizedString("Image", comment: "")
        case .file:
            return FileClipboardContent.displayTitle(for: item.preview)
        }
    }
```

替换为：

```swift
    private var displayText: String { item.displayTitle }
```

- [ ] **Step 3: 删除 `ClipItemRow` 中已下沉的 `firstLineTruncated`**

紧接上面、删除这一段（约 456-462 行）：

```swift
    /// 取文本首行，trim 后截断到 120 字符；空内容返回 nil
    private func firstLineTruncated(_ text: String, limit: Int = 120) -> String? {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
```

- [ ] **Step 4: `ClipItemRow` 的 `iconName` 改为转调扩展**

把这一段（约 486-493 行）：

```swift
    private var iconName: String {
        switch item.clipType {
        case .text:  return "doc.text"
        case .image: return "photo"
        case .file:  return "folder"
        case .url:   return "link"
        }
    }
```

替换为：

```swift
    private var iconName: String { item.typeIconName }
```

- [ ] **Step 5: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

注意：新建的 `.swift` 文件需被 Xcode 项目识别。`project.yml` 用目录通配收录 `Clipin/Views/`，`xcodegen generate` 已在前置准备执行；若编译报「找不到文件」，重跑 `xcodegen generate` 后再编译。

- [ ] **Step 6: 提交**

```bash
git add Clipin/Views/ClipListItem+Display.swift Clipin/Views/ClipItemRow.swift
git commit -m "$(cat <<'EOF'
refactor: 抽取 ClipListItem 展示标题与类型图标为共享扩展

【根因/背景】⌘K 动作面板头部要显示选中条目的图标+标题，与主列表 row
必须一致；推导逻辑原本私有在 ClipItemRow 内，面板无法复用。
【改动范围】新增 ClipListItem+Display.swift 扩展（displayTitle / typeIconName），
ClipItemRow 的 displayText / iconName 改为转调扩展，删除重复的 firstLineTruncated。
EOF
)"
```

---

## Task 3: 修滚动条闪烁 bug + 清理死代码

根因修复：面板开启时 `isShowingActions` 翻转，给「含 ScrollView 的视图」（主列表、预览区）加了 0.2% 的微缩放——肉眼不可见，但会让 macOS overlay 滚动条因 bounds 变化闪现一次。一并删除 `paletteScale`/`paletteLift`（条件插入视图上永不触发的死代码）与 `stripScale`（不可见微缩放）。

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`（`ClipinSceneState`，约 108-129 行）
- Modify: `Clipin/Views/PreviewPane.swift`（约 44 行）
- Modify: `Clipin/Views/MainPanel.swift`（约 179、274 行）
- Modify: `Clipin/Views/ActionPalette.swift`（约 109-111 行）

- [ ] **Step 1: 从 `ClipinSceneState` 删除四个死/有害属性**

在 `Clipin/App/ClipinTheme.swift` 的 `struct ClipinSceneState` 中删除以下三段。

删除 `previewScale`（约 108-110 行）：

```swift
    var previewScale: CGFloat {
        isShowingActions ? 0.998 : 1.0
    }

```

删除 `stripScale`（约 124-126 行）：

```swift
    var stripScale: CGFloat {
        isShowingActions ? 0.997 : 1.0
    }

```

删除 `paletteScale` / `paletteLift`（约 128-129 行）：

```swift
    var paletteScale: CGFloat { isShowingActions ? 1.0 : 0.985 }
    var paletteLift: CGFloat { isShowingActions ? 0 : 6 }
```

保留 `listRestingOpacity`、`previewLift`、`metadataOpacity`、`metadataLift`、`headerLift`、`selectedRow*` 等其余属性不动。

- [ ] **Step 2: `PreviewPane` 删除 `previewScale` 缩放**

在 `Clipin/Views/PreviewPane.swift` 约 44 行，删除这一行：

```swift
        .scaleEffect(sceneState.previewScale)
```

保留紧随其后的 `.offset(y: sceneState.previewLift)` 和 `.animation(ClipinMotion.focusShift, value: sceneState)` 不动。

- [ ] **Step 3: `MainPanel` 删除主列表的微缩放**

在 `Clipin/Views/MainPanel.swift` 的 `contentArea` 中，把 `itemList` 这一段（约 177-180 行）：

```swift
            itemList
                .frame(width: 292)
                .scaleEffect(sceneState.isShowingActions ? 0.998 : 1.0)
                .opacity(sceneState.listRestingOpacity)
```

改为（删中间的 `.scaleEffect`，保留 `.opacity` 焦点收束）：

```swift
            itemList
                .frame(width: 292)
                .opacity(sceneState.listRestingOpacity)
```

- [ ] **Step 4: `MainPanel` 删除底栏的 `stripScale`**

在 `bottomBarRow` 中删除这一行（约 274 行）：

```swift
        .scaleEffect(sceneState.stripScale)
```

- [ ] **Step 5: `ActionPalette` 删除死的 scene 缩放/位移**

在 `Clipin/Views/ActionPalette.swift` 的 `palettePanel` 中，把这一段（约 106-112 行）：

```swift
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)
        .scaleEffect(sceneState.paletteScale)
        .offset(y: sceneState.paletteLift)
        .animation(ClipinMotion.commandReveal, value: sceneState)
        .onAppear { selectedIndex = 0 }
```

改为：

```swift
        .padding(12)
        .frame(width: 372, alignment: .leading)
        .clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)
        .onAppear { selectedIndex = 0 }
```

> `ActionPalette` 的 `sceneState` 属性此时变为未使用，但 Swift 不会因未使用的存储属性报错；该属性会在 Task 4 重写签名时一并移除。

- [ ] **Step 6: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 提交**

```bash
git add Clipin/App/ClipinTheme.swift Clipin/Views/PreviewPane.swift Clipin/Views/MainPanel.swift Clipin/Views/ActionPalette.swift
git commit -m "$(cat <<'EOF'
fix: 修复 ⌘K 面板开启时主列表/预览闪现滚动条

【根因/背景】面板开启时 isShowingActions 翻转，给含 ScrollView 的主列表与
预览区加了 0.2% 微缩放——肉眼不可见，但 macOS overlay 滚动条只要 ScrollView
bounds 变化就会闪现一次。
【踩坑记录】paletteScale/paletteLift 是条件插入视图上永不触发的死代码（视图
出现时值已是终态）；stripScale 同属看不见的微缩放噪声。
【改动范围】ClipinSceneState 删除 previewScale/stripScale/paletteScale/paletteLift，
连同 PreviewPane、MainPanel、ActionPalette 的对应调用一并清理。
EOF
)"
```

---

## Task 4: ActionPalette 定位 + 悬浮投影 + 头部上下文

面板改为从底栏右下角长出（定位 padding 与底栏玻璃胶囊外接角重合）、加显式落影、头部显示选中条目的类型图标+标题。

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`（`enum ClipinChrome`，约 33 行后）
- Modify: `Clipin/Views/ActionPalette.swift`（签名、`body`、`palettePanel`、`paletteHeader`）
- Modify: `Clipin/Views/MainPanel.swift`（`ActionPalette(...)` 调用，约 119-136 行）

- [ ] **Step 1: 新增面板最大高度常量**

在 `Clipin/App/ClipinTheme.swift` 的 `enum ClipinChrome` 中，把：

```swift
    static let paletteCornerRadius: CGFloat = 26
```

改为：

```swift
    static let paletteCornerRadius: CGFloat = 26
    /// ⌘K 动作面板内容区最大高度（窗口 540 − 顶部搜索区呼吸位 ~72 − 底边距 8）。
    /// 超出则面板内层 ScrollView 滚动。
    static let paletteMaxHeight: CGFloat = 460
```

- [ ] **Step 2: `ActionPalette` 改签名——`sceneState` 换成 `selectedItem`**

在 `Clipin/Views/ActionPalette.swift` 的 `struct ActionPalette` 中，把：

```swift
    @Binding var selectedIndex: Int
    let sceneState: ClipinSceneState
    let onSelect: (Int) -> Void
```

改为：

```swift
    @Binding var selectedIndex: Int
    let selectedItem: ClipListItem?
    let onSelect: (Int) -> Void
```

- [ ] **Step 3: `ActionPalette` 改面板定位——右下角与底栏胶囊外接角重合**

在 `body` 中，把：

```swift
            palettePanel
                .padding(.trailing, ClipinChrome.shellGap)
                .padding(.bottom, ClipinChrome.floatingFooterBand + ClipinChrome.shellGap)
```

改为：

```swift
            palettePanel
                .padding(.trailing, ClipinChrome.shellGap * 2)
                .padding(.bottom, ClipinChrome.shellGap)
```

> 底栏 `bottomBarRow` 用的就是 `.padding(.horizontal, shellGap * 2)` + `.padding(.bottom, shellGap)`，因此面板右下角与底栏玻璃胶囊外接角精确重合。

- [ ] **Step 4: `ActionPalette` 给面板加悬浮投影**

在 `palettePanel` 中，把：

```swift
        .clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)
        .onAppear { selectedIndex = 0 }
```

改为：

```swift
        .clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)
        .shadow(color: paletteShadowColor, radius: 28, x: 0, y: 14)
        .onAppear { selectedIndex = 0 }
```

并在 `palettePanel` 计算属性下方新增 `paletteShadowColor`：

```swift
    /// native glassEffect 只给发丝 rim、不给落影；底栏淡出后右下角无第二层玻璃，
    /// 这层落影让面板干净地浮在内容之上。dark 模式窗体暗、需更深的影才立得住。
    private var paletteShadowColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.40 : 0.22)
    }
```

> `ActionPalette` 已有 `@Environment(\.colorScheme) private var colorScheme`，直接可用。

- [ ] **Step 5: `ActionPalette` 重写 `paletteHeader`——显示选中条目上下文**

把整个 `paletteHeader` 计算属性：

```swift
    private var paletteHeader: some View {
        HStack(spacing: 8) {
            Text("Actions")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            Spacer()

            ClipinKeycap(
                key: "Esc",
                foreground: ClipinInk.secondary
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
```

替换为：

```swift
    private var paletteHeader: some View {
        HStack(spacing: 8) {
            if let item = selectedItem {
                Image(systemName: item.typeIconName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Actions")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
            }

            Spacer(minLength: 8)

            ClipinKeycap(
                key: "Esc",
                foreground: ClipinInk.secondary
            )
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
```

- [ ] **Step 6: `MainPanel` 更新 `ActionPalette` 调用**

在 `Clipin/Views/MainPanel.swift` 中，把 `ActionPalette(...)` 调用里的：

```swift
                    actions: viewModel.paletteActions,
                    selectedIndex: $viewModel.selectedActionIndex,
                    sceneState: sceneState,
                    onSelect: { index in
```

改为：

```swift
                    actions: viewModel.paletteActions,
                    selectedIndex: $viewModel.selectedActionIndex,
                    selectedItem: viewModel.selectedListItem,
                    onSelect: { index in
```

- [ ] **Step 7: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: 提交**

```bash
git add Clipin/App/ClipinTheme.swift Clipin/Views/ActionPalette.swift Clipin/Views/MainPanel.swift
git commit -m "$(cat <<'EOF'
feat: ⌘K 面板贴底栏右下角定位、加悬浮投影与头部上下文

【根因/背景】面板原悬浮在底栏上方、与底栏割裂，头部只有死板的 Actions
字样。改为定位 padding 与底栏玻璃胶囊外接角重合，为「从 ⌘K 按钮长出」做
布局基础；头部显示选中条目的类型图标+标题。
【改动范围】ClipinChrome 新增 paletteMaxHeight；ActionPalette 签名 sceneState
换 selectedItem、定位 padding 调整、加 shadow、重写 paletteHeader；MainPanel
同步更新调用。
EOF
)"
```

---

## Task 5: ActionPalette 分组分隔线 + 最大高度 + 内层滚动

动作行区域包进内层 `ScrollView`，头部固定不滚；分组之间加 hairline 分隔线；面板高度封顶 `paletteMaxHeight`，超出可滚动且键盘选中跟随滚动。

**Files:**
- Modify: `Clipin/Views/ActionPalette.swift`（`palettePanel`、新增 `actionList`、新增 `actionsContentHeight` 状态）

- [ ] **Step 1: 新增内容高度测量状态**

在 `Clipin/Views/ActionPalette.swift` 的 `struct ActionPalette` 属性区，把：

```swift
    @State private var hoveredIndex: Int?
```

改为：

```swift
    @State private var hoveredIndex: Int?
    /// 动作行区域的自然高度，用于把面板封顶到 paletteMaxHeight（超出则内层滚动）。
    @State private var actionsContentHeight: CGFloat = 0
```

- [ ] **Step 2: `palettePanel` 把行区域换成 `actionList`**

把 `palettePanel` 中的：

```swift
            if actions.isEmpty {
                emptyState
            } else {
                ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 4) {
                        ForEach(group, id: \.self) { index in
                            actionRow(action: actions[index], index: index)
                        }
                    }
                }
            }
```

替换为：

```swift
            if actions.isEmpty {
                emptyState
            } else {
                actionList
            }
```

- [ ] **Step 3: 新增 `actionList` 计算属性**

在 `palettePanel` 计算属性之后、`paletteHeader` 之前（或 `groupedActionIndices` 附近）新增：

```swift
    /// 动作行区域：分组之间插 hairline 分隔线；包进内层 ScrollView 并按
    /// 自然高度封顶到 paletteMaxHeight；键盘移动选中时把选中行滚进可见区。
    private var actionList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groupedActionIndices.enumerated()), id: \.offset) { groupOrdinal, group in
                        if groupOrdinal > 0 {
                            Rectangle()
                                .fill(ClipinInk.tertiary.opacity(0.55))
                                .frame(height: 1)
                                .padding(.horizontal, ClipinChrome.listRowOuterInset)
                                .padding(.vertical, 5)
                        }
                        VStack(spacing: 4) {
                            ForEach(group, id: \.self) { index in
                                actionRow(action: actions[index], index: index)
                                    .id(index)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actionsContentHeight = $0 }
            }
            .frame(height: min(actionsContentHeight, ClipinChrome.paletteMaxHeight))
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation(ClipinMotion.feedback) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
```

> 说明：`onGeometryChange` 在首个布局 pass 即报告自然高度（与 `MainPanel` 的 `derivedPillsSize` 同款模式，默认值 0 在 SwiftUI 同一事务内被即时解析）；`.frame(height:)` 取 `min(自然高度, paletteMaxHeight)`，内容不足时面板按内容收缩、不留空白。`.id(index)` 让 `ScrollViewReader` 能精确滚到选中行。键盘 ↑↓ 改 `selectedIndex` 由 `AppDelegate.keyMonitor` 负责，`onChange` 只被动跟随滚动，不引入新的键盘语义。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add Clipin/Views/ActionPalette.swift
git commit -m "$(cat <<'EOF'
feat: ⌘K 面板加分组分隔线、最大高度与内层滚动

【根因/背景】面板原本所有动作行平铺在 VStack、无高度上限，富条目（带
HTML/RTF representation actions）会让面板无限长高；分组之间只有空白、层次弱。
【踩坑记录】ScrollView 默认贪婪占满可用空间，必须测量内容自然高度再取
min(自然高度, 上限) 才能做到「内容少则收缩、内容多则滚动」。
【改动范围】ActionPalette 新增 actionList：分组间插 hairline 分隔线、内层
ScrollView + ScrollViewReader 跟随 selectedIndex 滚动、按内容高度封顶到
paletteMaxHeight。
EOF
)"
```

---

## Task 6: 入场/退场动画 + 底栏淡出

面板从右下角 ⌘K 按钮缩放展开/收回；展开期间底栏两按钮同步淡出并停用点击。

**Files:**
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`（`showActionsPalette` / `hideActionsPalette`，约 94-105 行）
- Modify: `Clipin/Views/MainPanel.swift`（底栏 overlay 约 71-73 行、面板 `.transition` 约 137-145 行）

- [ ] **Step 1: `ClipboardViewModel` 给 `isShowingActions` 切换包 `withAnimation`**

需要 `import SwiftUI`——文件应已 import（`ClipboardViewModel` 用了 `@Published` 等）。若仅 import 了 `Foundation`/`Combine`，补一行 `import SwiftUI`。

把 `showActionsPalette()`（约 94-100 行）：

```swift
    func showActionsPalette() {
        let actions = ActionPaletteBuilder.actions(for: self)
        guard !actions.isEmpty else { return }
        paletteActions = actions
        selectedActionIndex = min(selectedActionIndex, max(actions.count - 1, 0))
        isShowingActions = true
    }
```

改为：

```swift
    func showActionsPalette() {
        let actions = ActionPaletteBuilder.actions(for: self)
        guard !actions.isEmpty else { return }
        paletteActions = actions
        selectedActionIndex = min(selectedActionIndex, max(actions.count - 1, 0))
        withAnimation(ClipinMotion.paletteReveal) {
            isShowingActions = true
        }
    }
```

把 `hideActionsPalette(restoreFocus:)` 开头（约 102-105 行）：

```swift
    func hideActionsPalette(restoreFocus: Bool = false) {
        isShowingActions = false
        paletteActions = []
        selectedActionIndex = 0
```

改为：

```swift
    func hideActionsPalette(restoreFocus: Bool = false) {
        withAnimation(ClipinMotion.paletteDismiss) {
            isShowingActions = false
        }
        paletteActions = []
        selectedActionIndex = 0
```

> `hideActionsPalette` 后续的 `if restoreFocus { ... }` 等代码保持不动。所有进出面板的路径都经由这两个方法（`toggleActionsPalette` / `executePaletteAction` / `loadItems` 静默刷新均转调它们），因此无需在别处再包动画。

- [ ] **Step 2: `MainPanel` 底栏开启面板时淡出 + 停用点击**

在 `Clipin/Views/MainPanel.swift` 中，把底栏 overlay（约 71-73 行）：

```swift
        .overlay(alignment: .bottom) {
            bottomBar
        }
```

改为：

```swift
        .overlay(alignment: .bottom) {
            bottomBar
                .opacity(viewModel.isShowingActions ? 0 : 1)
                .allowsHitTesting(!viewModel.isShowingActions)
        }
```

> opacity 变化会被 Step 1 的 `withAnimation` 事务带上，与面板缩放同步播放。`allowsHitTesting(false)` 防止点到面板下方的幽灵按钮、并避免误触发 `showsDerivedPills` 派生簇。

- [ ] **Step 3: `MainPanel` 改面板入场/退场过渡**

把面板的 `.transition(...)` 与其后的 `.animation(...)`（约 137-145 行）：

```swift
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.985, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .opacity
                    )
                )
            }
        }
        .animation(ClipinMotion.commandReveal, value: sceneState.isShowingActions)
```

改为（入场放大缩放幅度、退场也对称缩回；删掉 `.animation(_:value:)` 修饰符——动画改由 Step 1 的 `withAnimation` 驱动，保留它会与 `withAnimation` 抢事务、且无法区分入场/退场弹簧）：

```swift
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.90, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.93, anchor: .bottomTrailing).combined(with: .opacity)
                    )
                )
            }
        }
```

> 注意：被删的是 `.animation(ClipinMotion.commandReveal, value: sceneState.isShowingActions)` 这一行。`contentArea`（约 188 行）和 `headerBar`（约 172 行）各自的 `.animation(..., value: sceneState)` 不要动——主列表压暗等仍由它们独立驱动。

- [ ] **Step 4: 编译验证**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/Views/MainPanel.swift
git commit -m "$(cat <<'EOF'
feat: ⌘K 面板从底栏 ⌘K 按钮缩放展开/收回

【根因/背景】面板原入场只有 1.5% 缩放（肉眼不可见）+ opacity 淡入，像
凭空出现；退场只有 opacity 淡出，像飘走。
【踩坑记录】入场/退场要用不同弹簧，必须在切换 isShowingActions 处显式
withAnimation，不能用 .animation(_:value:) 修饰符（无法区分插入/移除）。
【改动范围】ClipboardViewModel 的 show/hideActionsPalette 分别包
paletteReveal / paletteDismiss；MainPanel 面板过渡改对称缩放（入场 0.90、
退场 0.93，锚点 bottomTrailing），底栏开启面板时同步淡出并停用点击。
EOF
)"
```

---

## Task 7: Release 构建 + 自截图视觉 QA

代码改动无 Rust 侧变化，无需 `cargo test`。本任务做完整 Release 构建并实操验证。

**Files:** 无（验证任务）

- [ ] **Step 1: Release 构建**

Run:
```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: 运行 app 并逐项视觉验证**

启动构建产物（`build/Release/Clipin.app` 或 Xcode 运行）。Clipin 是 `LSUIElement` menu bar app，截图用 `screencapture` 抓取面板窗口（参见既有 QA 习惯）。逐项确认：

1. ⌘K 开启：面板从右下角 ⌘K 按钮处缩放展开、盖住底栏，底栏两按钮（「粘贴到 Claude」「动作 ⌘K」）同步淡出。
2. Esc / 点面板外空白关闭：面板向右下角缩回、底栏淡回。
3. 开启与关闭的瞬间：主列表与预览区**不再闪现 overlay 滚动条**（这是本次主要 bug 修复，重点盯）。
4. 头部显示当前选中条目的类型图标 + 标题；空历史 / 无选中项时头部显示「Actions」。
5. 分组（粘贴类 / 次级 / 删除）之间有 1px hairline 分隔线。
6. 面板有可见落影，明显浮在内容之上。
7. 选中一个带多个 representation actions 的图片 / 文件条目，确认面板高度不超过上限、动作行区域可滚动；键盘 ↑↓ 把选中行滚进可见区、游标不滑出视野。
8. 键盘 ↑↓ / Return / Esc 行为与改动前一致；动作面板里的真实快捷键（⌘C / Space / ⌘⌫ 等）仍可直接触发。
9. dark / light 两种外观下都检查一遍投影与分隔线对比度是否舒适。

- [ ] **Step 3: 若有视觉问题，微调并补提交**

落影透明度 / 分隔线颜色 / 缩放幅度等纯视觉参数若在 QA 中觉得不到位，就地微调（`paletteShadowColor` 透明度、`Rectangle().fill(...)` 的 opacity、`.scale(scale:)` 数值），重新构建确认后补一个 `fix:` 提交。无问题则跳过。

---

## 自检（计划完成度对照 spec）

- **spec ① 入场/退场动画** → Task 6（withAnimation + 对称缩放过渡 + 底栏淡出）✅
- **spec ② 信息层次（头部上下文）** → Task 4 Step 5（重写 paletteHeader）✅
- **spec ② 信息层次（分组分隔线）** → Task 5 Step 3（hairline Rectangle）✅
- **spec ③ 最大高度 + 滚动** → Task 4 Step 1（paletteMaxHeight）+ Task 5（actionList ScrollView/ScrollViewReader）✅
- **spec ④ 悬浮感** → Task 4 Step 4（.shadow + paletteShadowColor）✅
- **spec ⑤ 滚动条 bug + 死代码清理** → Task 3（删 4 个 scene 属性 + 各调用点）✅
- **spec 受影响文件** → 全部覆盖：ClipinTheme / ActionPalette / MainPanel / PreviewPane / ClipboardViewModel，外加为「头部上下文」DRY 抽取的新文件 ClipListItem+Display.swift ✅
- **spec 非目标** → 未引入 matchedGeometryEffect、未做行级联、未加搜索框 ✅
- **类型一致性** → `displayTitle` / `typeIconName`（Task 2 定义，Task 4 使用）、`paletteReveal` / `paletteDismiss`（Task 1 定义，Task 6 使用）、`paletteMaxHeight`（Task 4 定义，Task 5 使用）、`actionsContentHeight`（Task 5 内自洽）命名前后一致 ✅
