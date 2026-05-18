# Raycast 优雅化主面板 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Clipin 主面板按 Raycast / macOS 26 的「减法」审美重构(选中减重+rail 退役、底栏改悬浮液态玻璃无底栏条、搜索去框、预览仅去发丝线、accent 稀用),源规格见 `docs/superpowers/specs/2026-05-18-raycast-elegance-refinement-design.md`。

**Architecture:** 纯 SwiftUI/AppKit 视图层改动,不动数据/Rust/键盘路由/窗口行为。改动按规格 5 个单元拆成 5 个任务,低风险隔离单元先做(A→D→C),最高风险的悬浮底栏+分区遮挡(B)放第 4 个单独验收,最后 E 做 accent 收敛核查+全量门+Codex 复审。同分支 `feat/liquid-glass-migration`(承接未并 main 的 Liquid Glass 视觉总工程)。

**Tech Stack:** SwiftUI(macOS 26 `.glassEffect`)、AppKit 桥接、xcodegen、xcodebuild。

**验证模型(重要,SwiftUI chrome 无断言测试):** 本仓 Swift UI 无单元测试 harness(测试仅 Rust `cargo test`),视觉 chrome 的验证 = ①`xcodebuild` Release 零警告通过 + ②规格 grep 门达期望值 + ③规格视觉逐项核查(由用户/Codex 目视,不可自动断言)。**不为 SwiftUI 视图编造假测试**。每个任务的「verify」步骤即上述可执行门;视觉项记录待用户验收(承接「绝不带病合并」)。每个任务 commit 用 CLAUDE.md 三段式中文格式,且**显式 `git add` 指定文件,绝不 `git add -A`**(防误带 `docs/superpowers/plans/2026-05-15-*` 等既有未跟踪文件)。

---

## File Structure

| 文件 | 职责 | 涉及任务 |
|---|---|---|
| `Clipin/App/ClipinTheme.swift` | `ClipinSelectionInk`/`ClipinHoverInk` 语义色中性化;`ClipinSelectableRowBackground` 删选中 rail+描边;新增 `ClipinChrome.floatingFooterBand` 单一度量常量 | T1, T4 |
| `Clipin/Views/ClipItemRow.swift` | 删选中加粗/变色/图标 accent/阴影;`trailingMeta` 仅当前选中行显示 | T1 |
| `Clipin/Views/MainPanel.swift` | `row(...)` 去 `showsSelectionAccent`;`bottomBar` 从 VStack 流式改 `.overlay(.bottom)` 悬浮离散玻璃;列表 scroll 底部 inset;notice 浮层 padding 调整 | T1, T4 |
| `Clipin/Views/PreviewPane.swift` | `PreviewFooterRail` 删 0.6pt 顶部发丝线 + 胶囊降安静;预览卡 `.padding(.bottom, floatingFooterBand)` | T2, T4 |
| `Clipin/Views/SearchBar.swift` | 删玻璃框;glyph 去衬底圆;clear 简化;filterChip 去 chrome(key-intercept/IME 字节不变) | T3 |

**已确认的代码现状(写计划时实读,避免冗余改动):** 列表区已被 `ClipinContentSurface`(`Color(nsColor:.controlBackgroundColor)`,系统**不透明**色)托底 → 规格「列表转不透明面」已满足,rail 退役本身根因安全,T1 **不需**再加换面改动(YAGNI)。

---

### Task 1: 单元 A —— 选中减重 + accent rail 退役 + D1 全局 token

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`(`ClipinSelectionInk` 347-352、`ClipinHoverInk` 355-358、`ClipinSelectableRowBackground` 245-295)
- Modify: `Clipin/Views/ClipItemRow.swift`(typeIndicator 103-140、body 86-99、trailingMeta 145-168)
- Modify: `Clipin/Views/MainPanel.swift`(`row(for:)` 520-531)

- [ ] **Step 1: 语义色中性化(D1 全局 token)**

`Clipin/App/ClipinTheme.swift` 把 `ClipinSelectionInk` / `ClipinHoverInk` 两个 enum 整体替换为:

```swift
/// 选中态语义色:列表/动作面板/侧栏共用,改一处调全局。
/// 减法重构后全部中性化(规格单元 A/E:accent 仅余 Paste 主键帽)。
enum ClipinSelectionInk {
    static let fill = Color.primary.opacity(0.07)          // 选中填充,明确强于 hover
    static let stroke = Color.primary.opacity(0.28)        // 仅余 pinned rail 用(中性)
    static let dim = Color.secondary                        // 选中态次要文字/⌘N,中性
    static let highlight = Color.accentColor.opacity(0.20)  // 仅搜索命中高亮保留极淡 accent
}

/// 悬停态语义色:与选中态同一套抓手,明确弱于选中。
enum ClipinHoverInk {
    static let fill = Color.primary.opacity(0.035)
    static let stroke = Color.clear
}
```

- [ ] **Step 2: `ClipinSelectableRowBackground` 删选中 rail + 删描边 overlay**

`Clipin/App/ClipinTheme.swift` 把 `struct ClipinSelectableRowBackground`(245-295)整体替换为:

```swift
/// 所有列表型界面的选中/悬停底板,主列表、动作面板、设置侧栏共用。
/// 减法重构:选中=单一中性填充(无 rail/无描边);pinned 仍用左侧中性细 rail 表达常驻 pin 状态。
struct ClipinSelectableRowBackground: View {
    let isSelected: Bool
    let isHovered: Bool
    let selectionFill: Color
    let selectionStroke: Color
    let hoverFill: Color
    let hoverStroke: Color
    var isPinned: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                .fill(
                    isSelected
                        ? selectionFill
                        : isHovered
                            ? hoverFill
                            : Color.clear
                )

            // pinned 态 rail:2pt 中性细条(非选中时表达常驻 pin 状态)。
            // 选中态不再画 rail/描边,仅靠中性填充区分。
            if isPinned && !isSelected {
                Capsule(style: .continuous)
                    .fill(selectionStroke.opacity(0.45))
                    .frame(width: 2)
                    .padding(.vertical, 11)
                    .padding(.leading, 7.5)
            }
        }
    }
}
```

说明:删除 `showsSelectionAccent` 属性、选中 rail 分支、`.overlay{ strokeBorder }` 整块(选中+hover 描边一并去,fill-only);`hoverStroke` 形参保留(其它调用点签名不破)但不再绘制。

- [ ] **Step 3: `MainPanel.row(for:)` 去掉 `showsSelectionAccent` 实参**

`Clipin/Views/MainPanel.swift` 520-531,把 `ClipinSelectableRowBackground(...)` 调用改为(删 `showsSelectionAccent: true,` 一行):

```swift
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: ClipinSelectionInk.fill,
                selectionStroke: ClipinSelectionInk.stroke,
                hoverFill: ClipinHoverInk.fill,
                hoverStroke: ClipinHoverInk.stroke,
                isPinned: item.isPinned
            )
        )
```

- [ ] **Step 4: `ClipItemRow` 删选中加粗/变色**

`Clipin/Views/ClipItemRow.swift` body 内 `Text(highlightedDisplayText)` 那段(86-90)替换为:

```swift
            Text(highlightedDisplayText)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(ClipinInk.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 5: `ClipItemRow` typeIndicator 去选中 accent(图标分支 + 占位分支)**

`Clipin/Views/ClipItemRow.swift` `ClipThumbnailImage` 占位分支(48-55)的 `foregroundStyle` / `fill` 去 isSelected:把 `.foregroundStyle(isSelected ? Color.accentColor : ClipinInk.secondary)` 改 `.foregroundStyle(ClipinInk.secondary)`;把 `.fill(isSelected ? ClipinSelectionInk.fill : Color(nsColor: .controlColor))` 改 `.fill(Color(nsColor: .controlColor))`。

`typeIndicator` 的 SF Symbol 分支(118-139)整体替换为:

```swift
        } else {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(ClipinHoverInk.stroke, lineWidth: 0.5)
                        )
                )
        }
```

(去掉 isSelected accent 前景、选中填充、accent 阴影 `.shadow(...)` 整块。)

- [ ] **Step 6: `ClipItemRow` trailingMeta 仅当前选中行显示**

`Clipin/Views/ClipItemRow.swift` body 内 `trailingMeta`(95 行处调用)外层包条件;把 body 的 `trailingMeta` 调用替换为:

```swift
            if isSelected {
                trailingMeta
            }
```

并把 `private var trailingMeta` 内 ⌘N 的 `.opacity(isSelected || isHovered ? 1.0 : 0.42)` 与 `.animation(ClipinMotion.feedback, value: isHovered)` 删除(选中时恒显,无需 hover 透明度);⌘N `foregroundStyle` 的 `isSelected ? ClipinSelectionInk.dim : ClipinInk.secondary` 简化为 `ClipinSelectionInk.dim`(现已=中性 secondary);时间戳 `foregroundStyle` 同理 `isSelected ? ClipinSelectionInk.dim : ClipinInk.tertiary` 简化为 `ClipinSelectionInk.dim`。

- [ ] **Step 7: 构建 + grep 门**

Run:
```
cd /Users/chenlei/work/person/Clipin && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`,无涉及 `showsSelectionAccent`/被删符号的警告。

Run:
```
grep -rn "showsSelectionAccent" Clipin/ --include='*.swift' | wc -l
grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l
```
Expected: 两者均为 `0`。

- [ ] **Step 8: Commit**

```bash
git add Clipin/App/ClipinTheme.swift Clipin/Views/ClipItemRow.swift Clipin/Views/MainPanel.swift
git commit -m "refactor: 单元A 选中减重+rail退役(D1全局token)

【根因/背景】accent rail 是「半透明面上多行看似同时选中」的补丁;列表已被不透明 ClipinContentSurface 托底,根因已消,rail 可退役。规格 2026-05-18 单元 A。
【踩坑记录】ClipinSelectionInk 是主列表/动作面板/设置侧栏共用全局 token,D1 确认改全局求一致;选中 fill 必须明确强于 hover(0.07 vs 0.035)否则无 rail 后两态难分。
【改动范围】ClipinTheme:SelectionInk/HoverInk 中性化、SelectableRowBackground 删选中 rail+描边;ClipItemRow 删加粗/变色/图标 accent/阴影、trailingMeta 仅选中行显示;MainPanel.row 去 showsSelectionAccent。"
```

---

### Task 2: 单元 D —— 预览胶囊条去 0.6pt 发丝线 + 降安静

**Files:**
- Modify: `Clipin/Views/PreviewPane.swift`(`PreviewFooterRail` 721-744、`PreviewValueBadge` 692-719)

- [ ] **Step 1: 删 `PreviewFooterRail` 顶部 0.6pt 发丝线**

`Clipin/Views/PreviewPane.swift` 把 `private struct PreviewFooterRail`(721-744)整体替换为:

```swift
private struct PreviewFooterRail: View {
    let entries: [PreviewPane.PreviewRailEntry]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    PreviewValueBadge(
                        item: entry.item,
                        prominence: entry.prominence
                    )
                }
            }
            .padding(.horizontal, 1)
            .padding(.top, 8)
            .padding(.bottom, 1)
        }
    }
}
```

(删除 `.overlay(alignment: .top){ Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.6) }` 整块;分隔改由抬起预览卡边界承担。)

- [ ] **Step 2: 胶囊降为「卡内安静注脚」**

`Clipin/Views/PreviewPane.swift` `PreviewValueBadge` body 内 `.foregroundStyle(item.emphasis ? Color.accentColor : ClipinInk.secondary)`(713)改为(去 emphasis 的 accent,统一中性,符合单元 E):

```swift
        .foregroundStyle(ClipinInk.secondary)
```

- [ ] **Step 3: 构建门**

Run:
```
cd /Users/chenlei/work/person/Clipin && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`。

Run:
```
grep -n "frame(height: 0.6)" Clipin/Views/PreviewPane.swift | wc -l
```
Expected: `0`(发丝线已删)。

- [ ] **Step 4: Commit**

```bash
git add Clipin/Views/PreviewPane.swift
git commit -m "refactor: 单元D 预览胶囊条去发丝线+降安静

【根因/背景】macOS 26 分隔靠材质深度不靠画线;那条 0.6pt 顶线是补丁,分隔应由抬起预览卡边界承担。规格 2026-05-18 单元 D。
【踩坑记录】胶囊形态/数据层用户明确要保留,本次只去线+把 emphasis 的 accent 收成中性,不动 footerEntries/*Badge 数据。
【改动范围】PreviewPane:PreviewFooterRail 删顶部 0.6pt overlay;PreviewValueBadge 前景统一中性。"
```

---

### Task 3: 单元 C —— 搜索 borderless 去框

**Files:**
- Modify: `Clipin/Views/SearchBar.swift`(`SearchBar.body` 192-227、`searchGlyph` 229-238)

- [ ] **Step 1: 删玻璃框 + clear 按钮简化**

`Clipin/Views/SearchBar.swift` `var body`(192-227)整体替换为:

```swift
    var body: some View {
        HStack(spacing: 9) {
            searchGlyph

            InterceptingTextFieldView(
                text: $query,
                placeholder: NSLocalizedString("Search clipboard history…", comment: ""),
                onNavigate: onNavigate,
                onSubmit: onSubmit,
                onEscape: onEscape,
                onTab: onCycleBrowseMode
            )
            .frame(height: 16)
            .layoutPriority(-1)

            filterChip

            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ClipinInk.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }
```

(删 `.clipinChromeGlass(cornerRadius: ClipinChrome.searchCornerRadius)`;clear 按钮去掉 `Circle().fill(controlColor)` 衬底,纯 inline。)

- [ ] **Step 2: searchGlyph 去衬底圆,纯 inline symbol**

`Clipin/Views/SearchBar.swift` `private var searchGlyph`(229-238)整体替换为:

```swift
    private var searchGlyph: some View {
        Image(systemName: "magnifyingglass")
            .foregroundStyle(ClipinInk.secondary)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 20, height: 24)
    }
```

- [ ] **Step 3: 构建门 + 字节不变核查**

Run:
```
cd /Users/chenlei/work/person/Clipin && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3
git diff --stat Clipin/Views/SearchBar.swift
```
Expected: `** BUILD SUCCEEDED **`;`git diff` 仅触及 `body` 与 `searchGlyph`,`InterceptingTextField`/`Coordinator`/`controlTextDid*`/`doCommandBy`/`syncBindingText` 行**无变更**(key-intercept/IME 字节不变)。

Run:
```
grep -n "clipinChromeGlass" Clipin/Views/SearchBar.swift | wc -l
```
Expected: `0`。

- [ ] **Step 4: Commit**

```bash
git add Clipin/Views/SearchBar.swift
git commit -m "refactor: 单元C 搜索 borderless 去框

【根因/背景】Raycast 搜索无框,glyph+文字直接坐连续面;规格 2026-05-18 单元 C「减 chrome」。
【踩坑记录】只动 SwiftUI 呈现层(body/searchGlyph),InterceptingTextField/Coordinator/IME preedit/doCommandBy 必须字节级不变,靠 git diff --stat 核查无牵连。
【改动范围】SearchBar:删 clipinChromeGlass 玻璃框、glyph 去衬底圆、clear 按钮简化为 inline;键盘/IME 逻辑零改动。"
```

---

### Task 4: 单元 B —— 悬浮液态玻璃底栏 + 分区遮挡(选项 A)【最高风险,单独验收】

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`(`ClipinChrome` 24-53 新增 `floatingFooterBand`)
- Modify: `Clipin/Views/MainPanel.swift`(`panelContent` 36-62、`bottomBar` 166-272、`listContent` ScrollView 466-492)
- Modify: `Clipin/Views/PreviewPane.swift`(`contentStage` 46-57)

- [ ] **Step 1: 新增单一度量常量**

`Clipin/App/ClipinTheme.swift` `enum ClipinChrome` 内 `footerMinHeight` 那行(45)后新增:

```swift
    /// 悬浮液态玻璃底栏「外接带」高度(玻璃元件高 + 与窗口边间距)。
    /// 列表 scroll 底部 inset 与预览卡 bottom margin 共用此单一度量,防两处各算漂移。规格单元 B。
    static let floatingFooterBand: CGFloat = 56
```

- [ ] **Step 2: `bottomBar` 去容器玻璃长条,改离散悬浮玻璃**

`Clipin/Views/MainPanel.swift` `private var bottomBar`(166-272)末尾的修饰链(257-271)替换为(删 `.clipinChromeGlass(cornerRadius: ClipinChrome.sectionCornerRadius)` 容器玻璃长条;容器透明;离散元件各自带玻璃,见 Step 3):

```swift
        .padding(.horizontal, ClipinChrome.footerContentInset)
        .padding(.vertical, ClipinChrome.footerContentInset)
        .frame(minHeight: ClipinChrome.footerMinHeight)
        .onHover { hovering in
            withAnimation(ClipinMotion.commandReveal) {
                isFooterHovered = hovering
            }
        }
        .animation(ClipinMotion.commandReveal, value: isFooterHovered)
        .scaleEffect(sceneState.stripScale)
        .padding(.horizontal, ClipinChrome.shellGap * 2)
        .padding(.bottom, ClipinChrome.shellGap)
        .animation(ClipinMotion.focusShift, value: sceneState)
```

- [ ] **Step 3: 左 source 面包屑 / 右 Paste·Actions 各自玻璃胶囊**

`Clipin/Views/MainPanel.swift` `bottomBar` 的 `HStack` 内:
- 左侧把无选中分支的 `Text("Clipboard History")...`(227-229)替换为 source 面包屑胶囊,有选中时显示来源 app:

```swift
                sourceBreadcrumb
```

前置:`Clipin/Views/MainPanel.swift` 第 1 行 `import SwiftUI` 下补一行 `import AppKit`(`NSWorkspace`/`NSImage` 需要;当前文件仅 import SwiftUI)。

在 `bottomBar` 之后新增计算属性。**图标解析复用既有 `PreviewPane.sourceAppIcon` 的真实逻辑**(按 `item.sourceApp` bundleId 经 `urlForApplication` 解析,来源 app 未运行也可拿到;**不**用 fragile 的 runningApplications 匹配):

```swift
    /// 来源 app 图标:按 bundle id 解析(镜像 PreviewPane.sourceAppIcon,来源 app 未运行也可用)
    private func sourceAppIcon(for item: ClipItem) -> NSImage? {
        guard let bundleId = item.sourceApp,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var sourceBreadcrumb: some View {
        HStack(spacing: 7) {
            if let item = viewModel.selectedItem, let name = item.sourceName {
                if let icon = sourceAppIcon(for: item) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ClipinInk.secondary)
                }
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Text("Clipboard History")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .clipinChromeGlass(in: Capsule(style: .continuous))
    }
```

- 右侧 `Actions` 的 `commandCluster { ... }`(249-255)与 Paste CTA 已是 `.glassProminent`;把 `commandCluster` 形状从圆角矩形改胶囊:`commandCluster`(309-316)的 `.clipinChromeGlass(cornerRadius: ClipinChrome.badgeCornerRadius + 2)` 改 `.clipinChromeGlass(in: Capsule(style: .continuous))`。

> 说明:Paste CTA(`.buttonStyle(.glassProminent)`)、连续粘贴 pill、hover 命令簇均已是独立元件,删掉外层容器长条玻璃后它们自然成为各自悬浮玻璃胶囊;布局保持「左 sourceBreadcrumb / Spacer / 右 pill+Actions」。

- [ ] **Step 4: `panelContent` 把 bottomBar 从流式改悬浮 overlay + notice padding 调整**

`Clipin/Views/MainPanel.swift` `panelContent`(36-62):把 VStack 内 `bottomBar`(40)删除,VStack 仅 `headerBar` + `contentArea`;在 `.overlay(alignment: .bottom){ notice... }` 之外**新增**一个底部 overlay 渲染悬浮 bottomBar,并把 notice 的 `.padding(.bottom, ClipinChrome.footerMinHeight + ClipinChrome.shellGap * 3)`(57)改为 `.padding(.bottom, ClipinChrome.floatingFooterBand + ClipinChrome.shellGap)`。`panelContent` 改为:

```swift
    private var panelContent: some View {
        VStack(spacing: 0) {
            headerBar
            contentArea
        }
        .frame(width: 800, height: 540)
        .overlay(alignment: .top) {
            if viewModel.isContinuousPasteEnabled {
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 2)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .bottom) {
            if let notice = viewModel.launcherNotice {
                launcherNoticeBanner(notice)
                    .padding(.bottom, ClipinChrome.floatingFooterBand + ClipinChrome.shellGap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(ClipinMotion.panel, value: viewModel.isContinuousPasteEnabled)
        .animation(ClipinMotion.commandReveal, value: viewModel.launcherNotice?.id)
```

(保留该属性后续既有行,只改至此。)

- [ ] **Step 5: 列表 scroll 底部 inset(最后一行可达)**

`Clipin/Views/MainPanel.swift` `listContent`(466-492)的 `ScrollView { ... }` 加底部 safe-area inset。把内层 `LazyVStack { ... }.padding(.vertical, 6)` 之后、`ScrollView` 闭合处改为给 ScrollView 加修饰:在 `ScrollView {` 对应闭合 `}` 后(`.onChange` 之前)插入:

```swift
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: ClipinChrome.floatingFooterBand)
            }
```

- [ ] **Step 6: 预览卡含横滚条整体抬到玻璃带之上(选项 A)**

`Clipin/Views/PreviewPane.swift` `contentStage<Content>`(46-57)在 `.background(ClipinContentSurface(...))` 之后追加 `.padding(.bottom, ClipinChrome.floatingFooterBand)`,使预览卡(连同 `safeAreaInset(.bottom)` 的 `PreviewFooterRail`)整体位于悬浮玻璃带上方:

```swift
    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                ClipinContentSurface(
                    cornerRadius: ClipinChrome.detailStageCornerRadius,
                    elevated: true
                )
            )
            .padding(.bottom, ClipinChrome.floatingFooterBand)
    }
```

- [ ] **Step 7: 构建门 + 视觉项记录(待用户/Codex 目视)**

Run:
```
cd /Users/chenlei/work/person/Clipin && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5
grep -rn "clipinChromeGlass(cornerRadius: ClipinChrome.sectionCornerRadius)" Clipin/Views/MainPanel.swift | wc -l
```
Expected: `** BUILD SUCCEEDED **`;第二条为 `0`(底栏容器长条玻璃已删)。

视觉项(规格验证 #1/#2/#3①②,记录待用户目视,不自动断言):无底栏条/无分隔线;底部元件半透明、内容从后透出;列表滚到底最后一行可达;**预览卡含横滚胶囊条永远完整在玻璃带上方、任意选中/横滚位置 bottom-right Paste/Actions 都不遮**。

- [ ] **Step 8: Commit**

```bash
git add Clipin/App/ClipinTheme.swift Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift
git commit -m "refactor: 单元B 悬浮液态玻璃底栏+分区遮挡(选项A)

【根因/背景】迁移把底栏糊成长条玻璃(玻璃套玻璃),退化了 CLAUDE.md「透明 command area」原决策;Raycast/macOS 26 是离散玻璃悬浮于铺满内容之上。规格 2026-05-18 单元 B。
【踩坑记录】固定且可横滚交互的预览胶囊条不能落在遮挡型悬浮玻璃下(用户复审逮到的设计洞);选项 A:列表 scroll inset 沉浸穿玻璃、预览卡含条整体 bottom margin 抬到玻璃带上;两处共用单一 floatingFooterBand 度量防漂移。
【改动范围】ClipinChrome 新增 floatingFooterBand;MainPanel bottomBar 去容器长条玻璃+左 sourceBreadcrumb 胶囊、panelContent 改 .overlay(.bottom) 悬浮、列表 scroll 底部 inset、notice padding 调整;PreviewPane contentStage 加 bottom margin。"
```

---

### Task 5: 单元 E —— accent 收敛核查 + 全量验证门 + Codex 复审

**Files:**
- 仅核查/必要时微调(无新功能)

- [ ] **Step 1: accent 残留扫描**

Run:
```
cd /Users/chenlei/work/person/Clipin
grep -rn "Color.accentColor\|\.accentColor\|controlAccentColor" Clipin/Views/ClipItemRow.swift Clipin/Views/SearchBar.swift Clipin/App/ClipinTheme.swift
```
Expected:仅余规格允许处 —— `ClipinSelectionInk.highlight`(搜索命中极淡 accent)。其余 ClipItemRow/SearchBar 不应再有 accent;若有(非 highlight)则按单元 E 改中性后重 commit。Paste CTA 的 accent(`pasteCallToAction` 内 `Circle().fill(Color.accentColor)` 主键帽、连续粘贴 pill)属规格允许的「唯一强调」,保留。

- [ ] **Step 2: 全量验证门(规格「不遗留」)**

Run:
```
cd /Users/chenlei/work/person/Clipin
./scripts/build-rust.sh >/dev/null 2>&1 && echo rust-ok
xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -3
grep -rn "showsSelectionAccent" Clipin/ --include='*.swift' | wc -l
grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l
grep -rn "clipinChromeGlass(cornerRadius: ClipinChrome.sectionCornerRadius)" Clipin/Views/MainPanel.swift | wc -l
grep -n "frame(height: 0.6)" Clipin/Views/PreviewPane.swift | wc -l
grep -n "clipinChromeGlass" Clipin/Views/SearchBar.swift | wc -l
```
Expected:`rust-ok`;`** BUILD SUCCEEDED **` 零警告;后五条均为 `0`。

- [ ] **Step 3: Codex 无偏见复审(CLAUDE.md 强制)**

用 `codex:codex-rescue` 子代理对本分支 5 个 commit 做无偏见 review,重点查:单元 B 的悬浮遮挡 inset 计算(预览卡是否任意状态都在玻璃带上)、rail 退役全仓清理无悬空、accent 收敛是否彻底、是否有半转换态/兜底。Codex 报告问题交回修复(不自行直接改大改动)。

- [ ] **Step 4: 回归核查清单(交用户目视确认,不自动断言)**

记录待用户验收:键盘导航 / 类型筛选 / Esc 分层回退 / Tab 循环 / ⌥0-5 / Space 预览 / 连续粘贴夺焦恢复 / Quick Look / IME 实时搜索 —— 本计划不动这些路径,需确认未被牵连。规格视觉 10 项逐项目视。

- [ ] **Step 5:(如有微调)Commit**

```bash
git add <实际改动文件>
git commit -m "refactor: 单元E accent 收敛核查与全量验证门收尾

【根因/背景】规格单元 E:accent 全窗仅留 Paste 主键帽,其余中性。收尾核查 + Codex 复审。
【踩坑记录】<填实际发现;无则写「扫描无残留,全量门通过」>
【改动范围】<填实际;无代码改动则记为仅验证、无 commit>"
```
(无改动则跳过本步,不空 commit。)

---

## 不做(YAGNI / 非目标,承接规格)

- 不改 `ClipinChrome` 尺寸 token 数值(只新增 `floatingFooterBand` 单一度量,不改既有 insets/heights)。
- 不动窗口行为(panel KVC/safe-area/.nonactivatingPanel)、键盘路由、IME preedit、连续粘贴逻辑、Quick Look、辅助窗口。
- 不动预览胶囊条数据层(`footerEntries/*Badge`)与胶囊形态。
- 不加兜底/`@available`/compat shim;不留半转换态。
- 单元 A 列表区**不**额外换不透明面(已被 `ClipinContentSurface` 托底)。

## 执行顺序与风险

T1→T2→T3 为低风险隔离单元;**T4 最高风险**(悬浮 overlay 改布局 + 分区遮挡),其构建门后视觉项必须由用户目视通过方可视作完成,**绝不带病合并**(承接 Liquid Glass 总工程的「绝不带病合并」);T5 收敛+Codex。每任务独立 commit、独立可回滚。
