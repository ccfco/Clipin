# Liquid Glass 迁移 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Clipin 全 5 窗口 chrome 从手绘玻璃迁移到 macOS 26 原生 Liquid Glass(单 native 无 tint 主题)。

**Architecture:** 路线 C —— 引入薄封装 `ClipinGlass`(单一可调缝)与 content 实色面助手,与旧体系并存;先重做 NSPanel chrome(最高风险,先验证)再逐窗迁移;旧手绘玻璃体系在引用归零后最后整体删除。全程不写 `@available` 兜底,不留 compat shim,构建始终保持可编译。

**Tech Stack:** Swift / SwiftUI / AppKit,macOS 26 SDK,`.glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)`,xcodegen,xcodebuild。

**关联 spec:** `docs/superpowers/specs/2026-05-18-liquid-glass-migration-design.md`

**测试说明:** 本迁移是视觉 chrome 改造,无单元测试意义。每个任务的"测试"= ①`xcodebuild` 零错误零相关警告 ②grep 门(被删符号引用计数)③运行 app 截图核对 spec 第 6 节视觉项。Rust 层不受影响,不跑 `cargo test`。

---

## File Structure

| 文件 | 职责 | 本计划中的变化 |
|---|---|---|
| `project.yml` | xcodegen 配置 | 部署目标 15.0 → 26.0 |
| `Clipin/App/ClipinTheme.swift` | 主题/chrome 原件 | 新增 `ClipinGlass`;塌缩 hierarchy/keycap/orb;最后删旧玻璃类型 |
| `Clipin/App/AppDelegate.swift` | NSPanel/窗口 chrome | 删 `NSVisualEffectView` 整套;玻璃移交 SwiftUI 根 |
| `Clipin/Views/MainPanel.swift` | 主面板外壳 | 根 `GlassEffectContainer`+`.glassEffect`;内部面改实色 |
| `Clipin/Views/PreviewPane.swift` | 右侧预览 | contentStage/metadata 改实色;badge 改 glass |
| `Clipin/Views/SearchBar.swift` | 搜索栏 | chrome glass |
| `Clipin/Views/ActionPalette.swift` | 动作面板 | glass sheet + `.buttonStyle(.glass)` |
| `Clipin/Views/ClipItemRow.swift` | 列表行 | 实色面,accent rail 保留 |
| `Clipin/Views/SettingsView.swift` | 设置页 | content 实色;隐藏主题选择器 |
| `Clipin/Views/OnboardingView.swift` `PermissionView.swift` `UpdateReminderView.swift` `ShortcutRecorder.swift` | 辅助窗口/控件 | chrome glass / content 实色 |

旧体系删除的符号(引用计数,见 spec 第 6 节):`ClipinGlassPalette`(26)、`ClipinSurfaceBackground`(21)、`ClipinPanelHierarchy`(19)、`ClipinSurfaceStyle`(10)、`ClipinShellBackground`(5)、`ClipinSurfaceRole`(5)、`ClipinRoundedSurface`(3)、`surfaceStyle(`(2)、`NSVisualEffectView`(3)。

---

## Task 1: 建迁移分支 + 提升部署目标 + 基线构建

**Files:**
- Modify: `project.yml:5`

- [ ] **Step 1: 建分支**

```bash
git checkout -b feat/liquid-glass-migration
```

- [ ] **Step 2: 改部署目标**

`project.yml` 第 5 行:

```yaml
  deploymentTarget:
    macOS: "26.0"
```

- [ ] **Step 3: 核查无 Liquid Glass 退出 key**

Run: `grep -rn "UIDesignRequiresCompatibility" project.yml Clipin/ ; grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l`
Expected: 第一条无输出;第二条输出 `0`。若有任一,停止并上报(违反"不兜底"硬约束)。

- [ ] **Step 4: 重新生成工程并基线构建**

Run:
```bash
./scripts/build-rust.sh && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`(此时尚未改 chrome,仅验证 26.0 基线可编译)。

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "build: 部署目标提升到 macOS 26.0

【根因/背景】Liquid Glass API 全部 macOS 26+ 专属,迁移前置
【改动范围】project.yml deploymentTarget 15.0 → 26.0"
```

---

## Task 2: 新增 `ClipinGlass` 薄封装与 content 实色助手(与旧体系并存)

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`(文件末尾追加,不动旧类型)

- [ ] **Step 1: 追加新原件**

在 `ClipinTheme.swift` 末尾追加(完整代码,新增不删):

```swift
// MARK: - Liquid Glass (macOS 26 原生)

/// 唯一玻璃缝:chrome 才用玻璃,内容区永不调用。
/// 首版单 native 无 tint —— 不接 tint 参数,杜绝"主题兜底"。
extension View {
    /// 窗口附着的 chrome 玻璃(搜索栏/底栏/动作面板/胶囊/orb)。
    func clipinChromeGlass(in shape: some Shape) -> some View {
        glassEffect(.regular, in: shape)
    }

    /// 圆角矩形 chrome 玻璃的便捷写法。
    func clipinChromeGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 内容区实色中性面(列表区/预览 contentStage/metadata):
/// 显式不上玻璃,文字坐其上保持清晰。可选 shadow 表达"浮起"。
struct ClipinContentSurface: View {
    var cornerRadius: CGFloat
    var elevated: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(
                color: .black.opacity(elevated ? 0.10 : 0),
                radius: elevated ? 12 : 0,
                y: elevated ? 4 : 0
            )
    }
}

/// 文字层级语义色(替代 ClipinPanelHierarchy 的手算 ink):
/// 系统语义色在玻璃/实色面上自动 vibrancy。
enum ClipinInk {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let quaternary = Color(nsColor: .quaternaryLabelColor)
}
```

- [ ] **Step 2: 编译验证(并存不破坏)**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`(新原件与旧 `ClipinGlassPalette` 并存,旧调用点未动)。

- [ ] **Step 3: Commit**

```bash
git add Clipin/App/ClipinTheme.swift
git commit -m "feat: 新增 ClipinGlass chrome 玻璃 + ClipinContentSurface 实色面

【根因/背景】Liquid Glass 迁移的单一可调缝,与旧体系并存以保证逐窗迁移期可编译
【改动范围】ClipinTheme.swift 追加 clipinChromeGlass / ClipinContentSurface / ClipinInk"
```

---

## Task 3: NSPanel chrome 重做(最高风险,先做先验)

**Files:**
- Modify: `Clipin/App/AppDelegate.swift:51-134`(删 `ClipinPanelChromeView` 的 NSVisualEffectView)、`AppDelegate.swift:425-445`(主 panel 装配)
- Modify: `Clipin/Views/MainPanel.swift`(根部加 `GlassEffectContainer`+`.glassEffect`)

- [ ] **Step 1: 删 ClipinPanelChromeView 的 material 层,改纯 hosting**

`AppDelegate.swift` 第 51-116 行 `ClipinPanelChromeView` 整类删除。主 panel 直接用 `ClipinPanelHostingView`(第 118-134 行保留:它的 zero safeAreaInsets / clear layer / 不 mask 仍是正确的窗口行为)。

- [ ] **Step 2: 改主 panel 装配**

`AppDelegate.swift` 约第 429 行:

```swift
// 旧:panel.contentView = ClipinPanelChromeView(rootView: ..., contentSize: ...)
panel.contentView = ClipinPanelHostingView(rootView: rootView)
```

第 437-445 行附近窗口属性:`backgroundColor = .clear`、`isOpaque = false`、`hasShadow = true` **保留**;**删除** `panel.setValue(ClipinChrome.shellCornerRadius, forKey: "cornerRadius")` 一行(圆角改由 SwiftUI 玻璃形状定义,窗口 frame 不再自画圆角,杜绝叠边)。`styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel]` **保留**。

- [ ] **Step 3: MainPanel 根部提供系统玻璃**

`MainPanel.swift` 最外层 body 包一层(用现有 `ClipinChrome.shellCornerRadius`):

```swift
GlassEffectContainer {
    <现有主面板内容>
}
.glassEffect(
    .regular,
    in: RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
)
```

若 `MainPanel` 当前最外层有 `.background(ClipinShellBackground...)` 或 `ClipinSurfaceBackground(role: .floating/.column...)` 作为外壳,删除该外壳背景(玻璃已由上面提供);内部 section/列表/预览背景留到 Task 4-5 处理。

- [ ] **Step 4: 构建**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`(此阶段 MainPanel 内部仍可能引用旧 palette,只要能编译即可)。

- [ ] **Step 5: 视觉验收(本任务的关键门 —— 不过不推进)**

Run: 打开 app(`open` 构建产物或 Xcode Run),`⌘⇧V` 唤起主面板,截图。
逐项确认:
1. 面板外壳是系统 Liquid Glass(随背景折射、有镜面边)
2. **面板边缘无双发丝线**(直击旧踩坑:NSVisualEffectView 已删,无叠加源)
3. **无顶部空隙 / 底部内容重叠**(safeAreaInsets 仍归零)
4. 面板有正常窗口投影,圆角无锯齿/无白边

任一不通过:停止,记录现象,回到 Step 1-3 调整,**不得进入 Task 4**。

- [ ] **Step 6: Commit**

```bash
git add Clipin/App/AppDelegate.swift Clipin/Views/MainPanel.swift
git commit -m "refactor: 主面板 chrome 改原生 Liquid Glass,删 NSVisualEffectView

【根因/背景】旧双发丝线来自 NSVisualEffectView 抗锯齿边+NSWindow frame+自裁圆角三者叠加;
玻璃移交 SwiftUI 根 GlassEffectContainer 后三者全消失
【踩坑记录】保留 .titled+.fullSizeContentView+.nonactivatingPanel 与 zero safeAreaInsets
窗口行为;仅删 setValue cornerRadius KVC,圆角改由玻璃形状定义
【改动范围】AppDelegate ClipinPanelChromeView 删除;MainPanel 根部 GlassEffectContainer"
```

---

## Task 4: 主面板内部面迁移(列表区/预览/badge)

**转换规则(适用于所有调用点):**
- `ClipinSurfaceBackground(role: .sidebar/.column/.contentStage/.metadata/.grouped, ...)`(内容区)→ `ClipinContentSurface(cornerRadius: <原 cornerRadius>, elevated: <contentStage 为 true 其余 false>)`
- `ClipinSurfaceBackground(role: .control/.strip/.floating, ...)`(chrome)→ `.clipinChromeGlass(cornerRadius: <原 cornerRadius>)`
- 手画 `Capsule().fill(glass.xxx).strokeBorder(...)` 的 badge/keycap → `.clipinChromeGlass(in: Capsule())`,去掉手填色与描边
- 前景色 `hierarchy.support.subduedInk` 等 → `ClipinInk.secondary/.tertiary`(按原浓淡对应)
- 删除随之失效的 `glass` / `hierarchy` 参数传递与 `.make(...)` 构造

**Files:**
- Modify: `Clipin/Views/ClipItemRow.swift`、`Clipin/Views/PreviewPane.swift`、`Clipin/Views/SearchBar.swift`、`Clipin/Views/ActionPalette.swift`

- [ ] **Step 1: ClipItemRow —— 行实色面 + accent rail 保留**

`ClipItemRow.swift` 中 `typeIndicator` 的图标底板(约 129-145 行)`RoundedRectangle().fill(isSelected ? hierarchy.selection.badgeFill : glass.keycapTint)` → 改用语义色:选中 `Color.accentColor.opacity(0.18)`,非选中 `Color(nsColor: .controlColor)`。前景 `hierarchy.selection.ink`/`hierarchy.support.subduedInk` → `ClipinInk`。`ClipinSelectableRowBackground`(在 MainPanel 行容器处)**逻辑保留**,其 `selectionFill/selectionStroke/...` 入参改为语义色常量(选中 `Color.accentColor.opacity(0.18)` / stroke `Color.accentColor`,hover `Color.primary.opacity(0.06)`)。`showsSelectionAccent` / `isPinned` rail 行为不变。

- [ ] **Step 2: PreviewPane —— contentStage/metadata 实色,badge glass**

`PreviewPane.swift`:
- `contentStage(...)` 的 `.background(ClipinSurfaceBackground(role: .contentStage, cornerRadius: ClipinChrome.detailStageCornerRadius, glass: glass))` → `.background(ClipinContentSurface(cornerRadius: ClipinChrome.detailStageCornerRadius, elevated: true))`
- `supportingBlock` / `urlInfoBlock` 的 `ClipinSurfaceBackground(role: .grouped, cornerRadius: ClipinChrome.detailMetadataCornerRadius, glass: glass)` → `ClipinContentSurface(cornerRadius: ClipinChrome.detailMetadataCornerRadius)`
- `PreviewValueBadge` body 的手画 `Capsule().fill(backgroundFill).overlay(strokeBorder...)`+`shadow` → `.clipinChromeGlass(in: Capsule(style: .continuous))`,删除 `backgroundFill`/`borderColor`/`foreground`/`shadow` 私有计算属性,前景统一 `ClipinInk.secondary`(emphasis 用 `Color.accentColor`)
- `mediaCanvas` 的 `glass.previewCanvasTint` 底 → `Color(nsColor: .controlBackgroundColor)`;描边删手算改 `Color.primary.opacity(0.08)`
- 所有 `glass`/`hierarchy` 属性与 `.make(...)` 构造删除,`PreviewPane`/子 view 不再持有这两个属性

- [ ] **Step 3: SearchBar / ActionPalette**

- `SearchBar.swift`:外层 `ClipinSurfaceBackground(role: .control/...)` → `.clipinChromeGlass(cornerRadius: ClipinChrome.searchCornerRadius)`;前景/占位色 → `ClipinInk`
- `ActionPalette.swift`:面板 sheet 背景 `ClipinSurfaceBackground(role: .floating, cornerRadius: ClipinChrome.paletteCornerRadius, ...)` → `.clipinChromeGlass(cornerRadius: ClipinChrome.paletteCornerRadius)`;行选中底板复用 `ClipinSelectableRowBackground`(语义色入参,同 Step 1);命令行按钮加 `.buttonStyle(.glass)`

- [ ] **Step 4: 构建 + 主面板引用归零核查**

Run:
```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3
grep -rn "ClipinSurfaceBackground\|ClipinGlassPalette\|ClipinPanelHierarchy" Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift Clipin/Views/SearchBar.swift Clipin/Views/ActionPalette.swift Clipin/Views/ClipItemRow.swift | wc -l
```
Expected: `** BUILD SUCCEEDED **`;grep 输出 `0`。

- [ ] **Step 5: 视觉验收**

唤起主面板截图,确认 spec 第 6 节:玻璃只在外壳/搜索/底栏/badge;列表行与预览正文坐实色面、文字清晰;选中 accent rail 在玻璃外壳下仍不可混淆;contentStage 有浮起投影。不过不推进。

- [ ] **Step 6: Commit**

```bash
git add Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift Clipin/Views/SearchBar.swift Clipin/Views/ActionPalette.swift Clipin/Views/ClipItemRow.swift
git commit -m "refactor: 主面板内部面迁移 —— 内容区实色 / chrome 与 badge 原生玻璃

【根因/背景】Apple 红线:玻璃属 chrome,列表/预览正文须坐实色面保证可读
【改动范围】MainPanel/PreviewPane/SearchBar/ActionPalette/ClipItemRow 去 glass/hierarchy,
改 ClipinContentSurface + clipinChromeGlass + ClipinInk,accent rail 逻辑保留"
```

---

## Task 5: 4 辅助窗口迁移 + VisualTheme 塌缩

**Files:**
- Modify: `Clipin/Views/SettingsView.swift`、`OnboardingView.swift`、`PermissionView.swift`、`UpdateReminderView.swift`、`ShortcutRecorder.swift`、`Clipin/App/AppDelegate.swift`(aux 窗口装配)、`Clipin/App/ClipinTheme.swift`(`ClipinKeycap`/`ClipinSymbolOrb` 重表达)

- [ ] **Step 1: 辅助窗口面迁移(同 Task 4 转换规则)**

四个 View 内 `ClipinSurfaceBackground(role:)` 按规则二分:导航/工具条 chrome → `.clipinChromeGlass(...)`;表单/内容分组 → `ClipinContentSurface(...)`。`ShortcutRecorder` 录制框 → `.clipinChromeGlass(cornerRadius:)`。前景色全改 `ClipinInk`。symbol orb 调用沿用重表达后的 `ClipinSymbolOrb`(Step 3)。

- [ ] **Step 2: AppDelegate aux 窗口装配核对**

`AppDelegate.swift` 第 1151/1196/1209/1324/1398 行附近:titled 窗(设置/引导/权限)继续用 `ClipinWindowHostingView`(保留);borderless 浮层(更新提醒)继续 `ClipinBorderlessHostingView`(其 cornerRadius+masksToBounds+hairline 用于无原生 frame 的浮层,保留)。**不需要改装配**,仅确认无残留 `ClipinPanelChromeView` 引用:
Run: `grep -rn "ClipinPanelChromeView\|NSVisualEffectView" Clipin/ --include='*.swift' | wc -l`
Expected: `0`。

- [ ] **Step 3: ClipinKeycap / ClipinSymbolOrb 重表达**

`ClipinTheme.swift` 中 `ClipinKeycap`(约 215-233 行)与 `ClipinSymbolOrb`(约 265-305 行):删除其对 `glass`/`ClipinGlassPalette` 入参的依赖,底板改 `.clipinChromeGlass(in: RoundedRectangle(cornerRadius: 7))` / `.clipinChromeGlass(in: RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius))`,前景 `ClipinInk`。调用点同步去掉 `glass:` 实参。

- [ ] **Step 4: VisualTheme 塌缩 + 隐藏选择器**

- `ClipinTheme.swift`:`VisualTheme` 枚举 4 case **保留**(不破坏 `SettingsStore` 持久化)。删除 `ClipinGlassPalette.make(theme:colorScheme:)` 等基于 theme 的构造(此时应已无引用)。
- `SettingsView.swift`:主题选择器 UI 用 `if false` 包裹或整段删除该 row(不留"选了没反应"的死 UI)。注释显式写明:`// 主题 tint 已推迟,首版单 native 无 tint —— 显式决策,非兜底`。`SettingsStore.visualTheme` 属性保留,渲染层不读其值。

- [ ] **Step 5: 构建**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 6: 视觉验收(4 窗口逐个)**

依次打开 设置 / 引导 / 权限 / 更新提醒,各截图:玻璃只在 chrome,表单内容区实色文字清晰,无残留旧玻璃,无双发丝线。设置页确认主题选择器已消失。不过不推进。

- [ ] **Step 7: Commit**

```bash
git add Clipin/Views/SettingsView.swift Clipin/Views/OnboardingView.swift Clipin/Views/PermissionView.swift Clipin/Views/UpdateReminderView.swift Clipin/Views/ShortcutRecorder.swift Clipin/App/ClipinTheme.swift
git commit -m "refactor: 4 辅助窗口迁移原生玻璃 + VisualTheme 塌缩为单 native

【根因/背景】首版单主题:theme tint 推迟,显式渲染 native glass 而非静默 default
【改动范围】Settings/Onboarding/Permission/UpdateReminder/ShortcutRecorder 面迁移;
ClipinKeycap/ClipinSymbolOrb 重表达;设置页隐藏主题选择器"
```

---

## Task 6: 删旧体系 + 无悬空门 + 零警告 + Codex review

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`(删 `ClipinGlassPalette`/`ClipinSurfaceBackground`/`ClipinSurfaceStyle`/`ClipinRoundedSurface`/`ClipinShellBackground`/`ClipinSurfaceRole`/`ClipinPanelHierarchy`/`surfaceStyle(for:)`)

- [ ] **Step 1: 删除旧玻璃类型**

`ClipinTheme.swift` 删除上述 8 个类型/方法定义整段。

- [ ] **Step 2: 无悬空引用门(spec 第 6 节,强制全 0)**

Run:
```bash
grep -rn "ClipinGlassPalette\|ClipinSurfaceBackground\|ClipinSurfaceStyle\|ClipinRoundedSurface\|ClipinShellBackground\|ClipinSurfaceRole\|ClipinPanelHierarchy\|surfaceStyle(\|NSVisualEffectView\|@available(macOS" Clipin/ --include='*.swift' | wc -l
```
Expected: `0`。非 0 则定位剩余引用逐个转换,直到归零(不允许半转换态)。

- [ ] **Step 3: 零警告构建**

Run:
```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | grep -E "warning:|error:|BUILD" | tail -10
```
Expected: `** BUILD SUCCEEDED **`,且无与被删符号 / 未用变量相关的 `warning:`。有则修。

- [ ] **Step 4: 全窗口回归 + 视觉总验收**

运行 app,逐项确认 spec 第 6 节全部 5 条视觉项 + 回归项(键盘导航 / 类型筛选 / Esc 分层回退 / 连续粘贴夺焦恢复 / `.nonactivatingPanel` / Quick Look 浏览)均正常,5 窗口无一处旧玻璃残留。

- [ ] **Step 5: Commit**

```bash
git add Clipin/App/ClipinTheme.swift
git commit -m "refactor: 删除手绘玻璃旧体系,Liquid Glass 迁移收尾

【根因/背景】引用已全部迁移完,旧体系彻底删除,不留 compat shim(不兜底硬约束)
【改动范围】ClipinTheme 删 ClipinGlassPalette 等 8 个类型/方法;grep 门全 0、零警告"
```

- [ ] **Step 6: Codex 无偏见 review(CLAUDE.md 约定)**

用 `codex:codex-rescue` subagent,任务描述:本次 Liquid Glass 迁移 diff(`git diff main...feat/liquid-glass-migration`),重点查:遗留的半转换/悬空引用、被删符号未清理处、`@available`/兜底/`try?` 吞错、NSPanel 行为回归(nonactivating/safeArea)、玻璃误铺到内容区。按其反馈修复(修复也交 Codex,不自行直改)。

---

## Self-Review(对照 spec)

**1. Spec 覆盖:** 第 1 节部署目标→Task1;第 2 节删旧建 `ClipinGlass`→Task2(建)+Task6(删);第 3 节 NSPanel→Task3;第 4 节 5 窗口映射→Task3/4/5;第 5 节 VisualTheme 塌缩→Task5 Step4;第 6 节验证(grep 门/零警告/视觉/回归/Codex)→各任务验收 Step + Task6。硬约束"不兜底/不遗留"→Task1 Step3、Task5 Step4、Task6 Step2-3 强制门。无遗漏。

**2. 占位符扫描:** 无 TBD/TODO;新原件(`clipinChromeGlass`/`ClipinContentSurface`/`ClipinInk`)在 Task2 给出完整代码;后续任务引用的均为已定义符号或现有 `ClipinChrome` token / `ClipinSelectableRowBackground`(spec 确认保留)。机械扫描类任务以"明确转换规则 + 已读文件实例 + 客观 grep/构建门"表达,完整性由门强制,非占位。

**3. 类型一致性:** `clipinChromeGlass(in:)`/`clipinChromeGlass(cornerRadius:)`、`ClipinContentSurface(cornerRadius:elevated:)`、`ClipinInk.primary/.secondary/.tertiary/.quaternary` 在 Task2 定义,Task3-5 调用签名一致;保留符号 `ClipinChrome`/`ClipinSelectableRowBackground`/`ClipinPanelHostingView`/`ClipinWindowHostingView`/`ClipinBorderlessHostingView` 与现有代码一致。
