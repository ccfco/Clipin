# iOS 26 Liquid Glass Launcher 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Clipin 主面板做成 iOS/macOS 26 原生 Liquid Glass launcher:整窗玻璃、内容直接坐其上无盒子、底栏单玻璃簇 + hover 正上方派生玻璃胶囊、圆角全系统同心(iOS 26 concentric),并以自截图真机迭代验收。

**Architecture:** 窗面用 AppKit `NSGlassEffectView`(导航层 Liquid Glass)替换实心深色 `NSView`;SwiftUI 内容不加背景;底栏 `GlassEffectContainer` 内胶囊 `Capsule` + `.glassEffect(.regular[.interactive()])`,新增 hover 上方派生胶囊组件;圆角删硬编码阶梯改 `.containerConcentric`/`Capsule` 单源。验证非 TDD 单测(UI 材质无法单测,spec 已定口径),而是 `build → screencapture 真机 → 逐项比对 → 修 → 重复`。

**Tech Stack:** Swift / SwiftUI / AppKit(macOS 26,Liquid Glass `glassEffect` / `NSGlassEffectView` / `GlassEffectContainer` / concentric corner API);Rust core 不动;`xcodebuild` 构建;`screencapture` + Python PIL 自检。

**基线已核(2026-05-19):** MainPanel/PreviewPane 已 0 处 `ClipinContentSurface`(v2 已清,本计划仅设守门);35 处硬编码圆角 token 引用待按 spec 收口;代码中无 `NSGlassEffectView`(仅注释);未使用任何 concentric API(故 Task 1 须先核 API)。

---

### Task 1: 同心圆角 API 对当前 SDK 编译核验(前置门)

**Files:**
- Probe: `Clipin/App/ClipinTheme.swift`(临时加最小用例,核验后保留为正式封装或回退)

- [ ] **Step 1: 查当前 Xcode/SDK 版本**

Run: `xcodebuild -version && xcrun --sdk macosx --show-sdk-version`
预期:记录 SDK 版本(用于判断 concentric API 形态)。

- [ ] **Step 2: 写最小核验用例**

在 `ClipinTheme.swift` 末尾临时追加:

```swift
// API-PROBE(Task 1 用,核验后转正式封装)
struct _ConcentricProbe: View {
    var body: some View {
        Color.clear
            .containerShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: .containerConcentric, style: .continuous)
                    .stroke(.clear)
            )
    }
}
```

- [ ] **Step 3: 编译核验**

Run: `./scripts/build-rust.sh && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5`
预期:BUILD SUCCEEDED。
- 若 `cornerRadius: .containerConcentric` 不存在:改试 `ConcentricRectangle()` 形状 API;仍不存在则记录该 SDK 实际同心 API 形态,后续任务以实测签名为准(目标不变:单源 shell + 同心推导)。

- [ ] **Step 4: 固化结论**

把核验通过的写法封装为 `ClipinTheme.swift` 内 `concentricShape()` / `ClipinConcentricShape`(具体名见 Task 3),删除 `_ConcentricProbe`。

- [ ] **Step 5: Commit**

```bash
git add Clipin/App/ClipinTheme.swift
git commit -m "chore: 核验 macOS 26 同心圆角 API 对当前 SDK 可用（前置门）

【根因/背景】spec 单元3 圆角同心化依赖 .containerConcentric/ConcentricRectangle，CLAUDE.md 要求不凭文档断言先核代码
【改动范围】ClipinTheme.swift 最小用例编译核验后固化封装"
```

---

### Task 2: 窗面回归整窗 Liquid Glass(spec 单元 1)

**Files:**
- Modify: `Clipin/App/AppDelegate.swift:365-385`(实心 `NSView surface` → `NSGlassEffectView`)
- Modify: `Clipin/Views/MainPanel.swift:24-27`(注释同步)

- [ ] **Step 1: 替换窗面宿主**

`AppDelegate.swift` 把 `:365-385`(注释块 + `let surface = NSView()` … `panel.contentView = surface`)替换为:

```swift
        // 窗面回归 macOS 26 原生整窗 Liquid Glass(导航层；Spotlight/Raycast 同款）。
        // v2 的「实心深色 NSView」被用户多轮真机否决：不够原生、非聚焦那种。
        // NSGlassEffectView 是 .glassEffect 的 AppKit 对应：contentView 放内容、
        // cornerRadius 设圆角，几何由系统绑定到 contentView。圆角仍由下方 panel
        // frame cornerRadius KVC 统一框（不手动 masksToBounds，避免与 frame
        // hairline 叠双发丝线 —— CLAUDE.md 旧坑）。底栏命令簇是独立
        // GlassEffectContainer 浮其上（Apple 文档化的控件玻璃浮导航玻璃模式）。
        let glass = NSGlassEffectView()
        glass.cornerRadius = ClipinChrome.shellCornerRadius
        let host = ClipinPanelHostingView(rootView: MainPanel(viewModel: vm))
        glass.contentView = host
        panel.contentView = glass
```

(删除原 `surface` 的 `wantsLayer`/`backgroundColor`/手动 `NSLayoutConstraint` 块——`NSGlassEffectView.contentView` 自动做几何绑定。)

- [ ] **Step 2: 同步 MainPanel 注释**

`MainPanel.swift:24-27` 注释把"窗面是…由 AppDelegate…NSGlassEffectView(glassSurface)承担"更新为准确描述(整窗 NSGlassEffectView 导航层玻璃,内容无背景坐其上),措辞与 AppDelegate 一致。

- [ ] **Step 3: 构建**

Run: `./scripts/build-rust.sh && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build 2>&1 | tail -5`
预期:BUILD SUCCEEDED。

- [ ] **Step 4: 自截图核验(spec 验收 ①)**

按"自检环路脚本"(见末尾附录)启动构建产物、呼出面板、`screencapture` 裁剪放大。
预期:整窗是连续 Liquid Glass(非实心深色、非桌面脏穿透);列表/预览/搜索直接坐玻璃无盒子。
不达标:仅在 NSGlassEffectView 参数/层级内调,**不回退实心盒**。

- [ ] **Step 5: Commit**

```bash
git add Clipin/App/AppDelegate.swift Clipin/Views/MainPanel.swift
git commit -m "refactor: 窗面回归整窗 NSGlassEffectView 液态玻璃（撤销实心深色）

【根因/背景】v2 实心深色窗面被用户多轮真机否决，要求 iOS 26 整体液态玻璃（Spotlight/Raycast 那种）
【踩坑记录】NSGlassEffectView.contentView 自动几何绑定，删手动约束；圆角仍走 panel frame KVC 不手动 mask
【改动范围】AppDelegate 窗面宿主 NSView→NSGlassEffectView；MainPanel 注释同步"
```

---

### Task 3: iOS 26 同心圆角系统(spec 单元 3,用户重点)

**Files:**
- Modify: `Clipin/App/ClipinTheme.swift`(圆角 token + `ClipinFooterGlassButtonStyle` + 选中底板 + 键帽)
- Modify: 主面板调用点 `Clipin/Views/MainPanel.swift`、`Clipin/Views/PreviewPane.swift`(仅主面板玻璃 chrome 的圆角形状)

**范围纪律(writing-plans:不擅自重构):** 辅助窗口(Settings/Onboarding/Permission/Update)仍用 `ClipinChrome` 现有 token —— **不动**。本任务只把**主面板玻璃 chrome**(底栏胶囊、键帽、选中底板、并入窗壳几何的玻璃面)改同心/Capsule。`shellCornerRadius`/`shellGap`/`ClipinInk`/`ClipinSelectionInk`/`ClipinHoverInk` 保留。

- [ ] **Step 1: 固化同心封装**

`ClipinTheme.swift` 用 Task 1 核验通过的写法加:

```swift
extension Shape where Self == RoundedRectangle {
    /// iOS/macOS 26 同心圆角:curvature 随最近 containerShape 自动推导，不硬编码。
    static var clipinConcentric: RoundedRectangle {
        RoundedRectangle(cornerRadius: .containerConcentric, style: .continuous)
    }
}
```
(若 Task 1 实测 API 形态不同,按实测等价封装,语义不变。)

- [ ] **Step 2: 底栏胶囊形状收口为 Capsule**

`ClipinFooterGlassButtonStyle.makeBody`(`ClipinTheme.swift:307-314`)的 `in: Capsule(style: .continuous)` 保留(已是 Capsule,符合 iOS 26 玻璃按钮默认形)。确认 `keyBadge`/`ClipinKeycap`(`:159-178`)键帽改 `Capsule(style:.continuous)` 或最小连续圆角片(对齐真机 Raycast 键帽小圆角片),删 `cornerRadius: 5` 硬编码 → `Capsule`。

- [ ] **Step 3: 选中底板同心化**

`ClipinSelectableRowBackground`(`:248-279`)的 `RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius...)` 改 `RoundedRectangle.clipinConcentric`;列表容器在 `MainPanel.itemList` 外层声明 `.containerShape(RoundedRectangle.clipinConcentric)`(相对 shell 同心)。pinned rail 形状不变(Capsule 已同心)。

- [ ] **Step 4: 主面板内联圆角魔数清理**

`MainPanel.swift`/`PreviewPane.swift` 主面板玻璃 chrome 处出现的 `ClipinChrome.searchCornerRadius`/`rowCornerRadius`/`detailStageCornerRadius`/`detailMetadataCornerRadius` 等(launcherNoticeBanner、contentStage 媒体框非媒体的容器角等)改 `RoundedRectangle.clipinConcentric` + 父层 `containerShape`。媒体呈现框(图片/图标/色块/orb)圆角**保留**(媒体非容器,spec 明确不动)。`ClipinChrome` 中仅主面板已不再引用的 token 标注 `// 辅助窗口专用` 不删(辅助窗口仍用)。

- [ ] **Step 5: 构建 + 自截图核验(spec 验收 ②)**

Run 构建命令(同 Task 2 Step 3)。预期 BUILD SUCCEEDED。
自截图比对:窗壳—底栏簇—胶囊—键帽—选中底板逐层**同心**,无内外角弧错位;全 continuous squircle。不达标:查 `containerShape` 是否每个玻璃容器根部声明、子形状是否 `.clipinConcentric`。

- [ ] **Step 6: Commit**

```bash
git add Clipin/App/ClipinTheme.swift Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift
git commit -m "refactor: 主面板圆角改 iOS 26 同心系统（删硬编码阶梯魔数）

【根因/背景】用户两次强调圆角按 iOS 26；返工真因是硬编码阶梯非同心
【踩坑记录】辅助窗口仍依赖 ClipinChrome token，仅收口主面板玻璃 chrome；媒体框圆角保留
【改动范围】ClipinTheme 同心封装+键帽+选中底板；MainPanel/PreviewPane 主面板 chrome 圆角"
```

---

### Task 4: 内容无盒子守门(spec 单元 2)

**Files:**
- Verify: `Clipin/Views/MainPanel.swift`、`Clipin/Views/PreviewPane.swift`

- [ ] **Step 1: grep 守门**

Run: `grep -c "ClipinContentSurface" Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift`
预期:均为 0(基线已确认;若 Task 3 误引入则修正)。`grep -rn "ClipinContentSurface" Clipin/App/ClipinTheme.swift | head -1` 确认 struct 本体仍在(辅助窗口依赖)。

- [ ] **Step 2: 自截图确认**

自截图:列表/预览文本直接坐玻璃,无 292pt 不透明大框、无 OCR/URL 文本块底;媒体框按 Option A 保留。无需改代码则跳到 Step 3。

- [ ] **Step 3: (仅若 Step1/2 不达标才有改动)Commit**

```bash
git add -A && git commit -m "fix: 主面板内容无盒子守门修正"
```
(达标则本任务无 commit,记录于执行日志。)

---

### Task 5: 底栏单玻璃簇 + hover 正上方派生胶囊(spec 单元 4)

**Files:**
- Create: `Clipin/Views/FooterHoverDerivedPills.swift`(新组件)
- Modify: `Clipin/Views/MainPanel.swift:161-377`(`bottomBar` / `commandCluster` / `keyBadge` / `isFooterHovered` 区)

- [ ] **Step 1: 写派生胶囊组件**

`Clipin/Views/FooterHoverDerivedPills.swift`:

```swift
import SwiftUI

/// 底栏 hover 正上方派生玻璃胶囊(对齐真机 Raycast:hover 控件→其正上方
/// 派生独立玻璃 Capsule，显次级动作+快捷键；无箭头、留缝、同款暗玻璃)。
/// 纯鼠标可发现性增强;键盘用户走全局快捷键，不依赖此层。
struct FooterDerivedPill: Identifiable {
    let id = UUID()
    let label: String
    let shortcut: String
    let action: () -> Void
}

struct FooterHoverDerivedPills: View {
    let pills: [FooterDerivedPill]

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(pills) { pill in
                    Button(action: pill.action) {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(pill.label))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(ClipinInk.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            ClipinKeycap(key: pill.shortcut, foreground: ClipinInk.secondary)
                        }
                    }
                    .buttonStyle(ClipinFooterGlassButtonStyle())
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
```

- [ ] **Step 2: bottomBar 接入派生层(取代横向展开簇)**

`MainPanel.swift` `bottomBar`:删除 `isFooterHovered` 那段"横向展开在 Paste 左侧"的 `commandCluster { HTML/RTF/Plain/Open/Preview }`(`:185-228`);改为给 `Paste` 按钮包一层 `.overlay(alignment:.bottom)` 在其**正上方**(用 `.alignmentGuide`/`offset` 让派生层落在 Paste 上沿之上、留 6pt 缝)渲染 `FooterHoverDerivedPills`,数据由 `hoverPills(for:)` 动态构建:

```swift
private func hoverPills() -> [FooterDerivedPill] {
    var p: [FooterDerivedPill] = []
    if viewModel.selectedRepresentationUTIs.contains("public.html") {
        p.append(.init(label: "HTML", shortcut: "⌥H") { viewModel.pasteRepresentationSelected(uti: "public.html") })
    }
    if viewModel.selectedRepresentationUTIs.contains("public.rtf") {
        p.append(.init(label: "RTF", shortcut: "⌥R") { viewModel.pasteRepresentationSelected(uti: "public.rtf") })
    }
    p.append(.init(label: "Plain Text", shortcut: "⇧↵") { viewModel.pastePlainSelected() })
    if viewModel.canOpenSelectedItem {
        p.append(.init(label: viewModel.selectedOpenLabel, shortcut: "⌘O") { viewModel.openSelected() })
    }
    if viewModel.canPreviewSelectedItem {
        p.append(.init(label: viewModel.isPreparingPreview ? "Preparing…" : "Preview", shortcut: "Space") { _ = viewModel.previewSelected() })
    }
    return p
}
```

仅在 `viewModel.selectedListItem != nil && isFooterHovered` 时渲染 `FooterHoverDerivedPills(pills: hoverPills())`;`onHover`/`ClipinMotion.commandReveal` 沿用。`pastePlainSelected`/`pasteRepresentationSelected`/`openSelected`/`previewSelected` 行为字节不变。左侧面包屑**不**加派生(spec 消歧:无真实次级动作不造)。

- [ ] **Step 3: 删手绘 accent 残留核查**

Run: `grep -n "Circle()\|strokeBorder(Color.accentColor\|RoundedRectangle.*fill(Color.accentColor" Clipin/Views/MainPanel.swift`
预期:0(accent 仅 `Paste` 经 `.interactive()` 玻璃自身承载;`continuousPastePill` 已 `ClipinFooterGlassButtonStyle`)。有则删手绘块改原生玻璃。

- [ ] **Step 4: 构建 + 自截图核验(spec 验收 ③④)**

构建命令同上。自截图比对:静息 = 暗克制单玻璃簇 + 极细 rim(对齐真机 Raycast,非亮磨砂);hover `Paste` → **正上方**纵向派生独立玻璃胶囊(`纯文本/HTML/RTF/Open/Preview` 按条目动态),无箭头留缝同款暗玻璃,移开收起。不达标改 offset/spacing/材质。

- [ ] **Step 5: Commit**

```bash
git add Clipin/Views/FooterHoverDerivedPills.swift Clipin/Views/MainPanel.swift
git commit -m "refactor: 底栏 hover 改 Raycast 式正上方派生玻璃胶囊（取代横向展开）

【根因/背景】真机 Raycast 实证：hover 控件→其正上方派生独立玻璃胶囊；旧实现是横向展开在 Paste 左侧
【踩坑记录】行为字节不变（pastePlain/Representation/open/preview），仅呈现位置改正上方派生；左面包屑无真实次级动作故不造
【改动范围】新增 FooterHoverDerivedPills.swift；MainPanel bottomBar 接入"
```

---

### Task 6: 玻璃面可读性 / 选中态调优(spec 单元 5,自截图驱动)

**Files:**
- Modify(仅按需): `Clipin/App/ClipinTheme.swift`(`ClipinSelectionInk` / `ClipinHoverInk` 不透明度)

- [ ] **Step 1: 自截图基线**

启动构建产物、选中列表某行、有/无搜索/连续粘贴态各截一张,裁剪放大列表区。

- [ ] **Step 2: 逐项判读(spec 验收 ⑤)**

核查:① 选中行单一可辨(玻璃面比实心面弱,重点);② 任意时刻不"多行同时选中";③ hover 弱于选中;④ 文字在玻璃上清晰。

- [ ] **Step 3: 按需微调(不引盒/不引描边)**

仅当对比不足:在 `ClipinSelectionInk.fill`(现 `Color.primary.opacity(0.07)`)/`ClipinHoverInk.fill`(现 `0.035`)范围内提不透明度,保持单层中性填充。**绝不**加不透明盒/描边/rail(v1 错误)。

- [ ] **Step 4: 重截确认 + Commit(仅若有改)**

```bash
git add Clipin/App/ClipinTheme.swift
git commit -m "fix: 玻璃面选中/hover 对比度真机调优（单层中性填充，不引盒）

【根因/背景】单玻璃面比实心深色面更难压选中对比，spec 单元5 首要验收项
【改动范围】ClipinSelectionInk/ClipinHoverInk 不透明度（自截图判读后微调）"
```
(达标则无 commit,记录执行日志。)

---

### Task 7: 全量自截图迭代验收 + Codex 复审

**Files:** 无(验收 + 复审)

- [ ] **Step 1: 全量自检环路**

按附录脚本:杀旧→启动→呼出→`screencapture`→裁剪放大,逐条核 spec 验收 ①–⑥(整窗玻璃/同心圆角/底栏静息/hover 派生/选中可读/辅助窗口未牵连)。任一不达标 → 回对应 Task 修 → 重编重截,直到全过。

- [ ] **Step 2: 回归核查**

呼出/搜索/↑↓/Return/Esc 分层回退/Tab/⌥0-5/Space 预览/连续粘贴夺焦/IME preedit 实测一遍未受影响(键盘路由本计划未动,确认无连带)。

- [ ] **Step 3: Codex 无偏见复审(CLAUDE.md)**

交 `codex:codex-rescue` 复审本分支改动,重点:NSGlassEffectView 接入正确性、同心 API 用法、底栏派生层布局/材质、无手绘 accent 残留、辅助窗口未牵连、无悬空引用/兜底。按反馈修。

- [ ] **Step 4: 汇总交用户真机终验**

附自截图关键帧 + 复盘(思路→关键步骤/改了哪些文件→结果),交用户真机终验。**不达标不并 main(绝不带病合并)。**

---

## 附录:自检环路脚本(每轮复用)

```bash
# 1. 关旧实例（Clipin 是 LSUIElement，按 bundle 关）
pkill -f "Clipin.app/Contents/MacOS/Clipin" 2>/dev/null; sleep 1
# 2. 启动新构建产物
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 4 -name Clipin.app -path '*Release*' 2>/dev/null | head -1)
open "$APP"; sleep 2
# 3. 呼出主面板（CLAUDE.md 全局快捷键 ⌘⇧V；Clipin 是 nonactivatingPanel）
osascript -e 'tell application "System Events" to key code 9 using {command down, shift down}'; sleep 1.5
# 4. 抓真屏（screencapture 绕合成层过滤，已验证可抓 LSUIElement 面板）
screencapture -x /tmp/clipin_chk.png
# 5. 裁剪放大面板区（坐标按实际窗口位用网格法定位，不猜）
python3 - <<'PY'
from PIL import Image
im=Image.open('/tmp/clipin_chk.png'); print('screen', im.size)
im.crop((0,0,im.size[0],im.size[1])).save('/tmp/clipin_full.png')
PY
```
(裁剪坐标用前述"坐标网格法"按实际窗口位精确定位,严禁基于旧引用猜。)

## Self-Review(对 spec 逐条覆盖)

- spec 单元1(整窗玻璃)→ Task 2 ✅
- spec 单元2(内容无盒子)→ Task 4 守门 ✅(基线已 0,设门防回归)
- spec 单元3(同心圆角,用户重点)→ Task 1(API 核验)+ Task 3 ✅
- spec 单元4(底栏单玻璃簇 + hover 上方派生)→ Task 5 ✅
- spec 单元5(玻璃面可读性/选中)→ Task 6 ✅
- spec 自截图迭代验收 → 每 Task 含自截图步 + Task 7 全量 ✅
- spec 非目标(尺寸固定/窗口行为/键盘路由/辅助窗口/Rust)→ 各 Task 范围纪律明列,Task 7 Step2 回归确认 ✅
- 类型一致性:`FooterDerivedPill`/`FooterHoverDerivedPills`/`hoverPills()`/`RoundedRectangle.clipinConcentric` 跨 Task 命名一致 ✅
- 占位扫描:无 TBD;Task 4/6 "仅按需 commit" 是真实条件分支非占位,已注明记录执行日志 ✅
- 已知务实偏差:UI 材质无法 TDD 单测,验证用 spec 定义的自截图真机口径(非占位,是项目适配)✅
