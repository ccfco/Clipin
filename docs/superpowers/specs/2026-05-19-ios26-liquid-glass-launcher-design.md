# Clipin 主面板 — iOS/macOS 26 Liquid Glass launcher(整窗玻璃 · 单玻璃双栏)

- 日期:2026-05-19
- 状态:**方向已由用户多轮锁定,用户明确要求不再询问、直接做到成品并自截图迭代验收**
- 基线:`feat/liquid-glass-migration`,在 `84ee4a3`(单玻璃层=实心深色)之上做结构修正
- 关联前序:`docs/superpowers/specs/2026-05-18-raycast-elegance-refinement-design.md`(v2,本 spec 是其用户否决"实心深色"后的方向修正)

## 背景与根因(决策留痕)

- v2 spec 把窗面做成 **实心深色 NSView**(`AppDelegate.swift:373-375`),理由是"玻璃不能采样玻璃,底栏玻璃胶囊需实体背景"。
- 用户多轮真机比对后判定:**实心深色 ≠ 聚焦/Raycast 那种,不好看也不够原生**。用户最终拍板:**整个面板要 iOS 26 那种液态玻璃整体风格**,圆角弧度严格按 iOS 26。
- 真机参照已吃透(本会话用 `screencapture` 抓取 Raycast Beta / macOS 26 真实像素,非 mock 非臆测):
  - 底栏 = **一颗右对齐连续圆角胶囊**(大圆角矩形,非整药丸),内含 `Paste [↵]` + `Actions [⌘K]` 两个并排动作、中间一道极淡分隔;**静息即见极细玻璃 rim、fill 很暗很克制**(不是亮白磨砂大板);左侧是命令面包屑(图标 + 名称)亦为同款玻璃胶囊。
  - **hover 派生模型(关键)**:hover 底栏某个玻璃控件 → 在它**正上方**派生一颗**独立玻璃胶囊**,内容是该控件的次级动作 + 其快捷键(真机实证:hover 左侧 `Clipboard History` → 上方冒出 `About Menu  ⇧⌘K` 玻璃胶囊)。无箭头连接、留一点缝、同款暗玻璃。**不是 tooltip,是真玻璃小胶囊。**
- 关于"玻璃采样玻璃":Apple 的规范是**同一 `GlassEffectContainer` 内由系统统一融合**,容器提供共享采样区;launcher 整窗作为**导航层**用整面 Liquid Glass 是 Apple 官方做法(Spotlight 即如此),内容靠 vibrancy 直接坐其上。底栏命令簇是一个**独立 `GlassEffectContainer` 簇**浮在导航层玻璃之上 —— 这是 Apple 文档化的"toolbar/控件玻璃浮在玻璃导航面之上"的合法模式,不是禁止的无序 glass-on-glass。v2 的"实心深色"是对这条规范的过度规避。

## 目标

把主面板做成 **iOS/macOS 26 原生 Liquid Glass launcher**:整窗即一块 `NSGlassEffectView` 液态玻璃(Spotlight/Raycast 那种),列表/预览/搜索内容靠 vibrancy 直接坐玻璃上、**无任何不透明内层盒子**;底栏是一颗连续液态玻璃命令簇,hover 控件时其正上方派生独立玻璃胶囊提示次级快捷键。圆角全系统按 **iOS 26 同心圆角(concentric)** 原则,不靠硬编码魔数。

### 核心原则(每个改动单元服务这条)

1. **整窗玻璃**:窗面 = `NSGlassEffectView`(导航层 Liquid Glass);内容直接坐其上,无 `ClipinContentSurface` 盒子。
2. **底栏单玻璃簇 + hover 上方派生**:底栏命令收口为单个 `GlassEffectContainer`;hover 控件 → 正上方派生独立玻璃胶囊(取代现有"横向展开在 Paste 左侧"的 `isFooterHovered` 簇)。
3. **同心圆角**:除"窗壳半径"一个必须与 panel frame KVC 对齐的源 token 外,所有嵌套玻璃形状用 `RoundedRectangle(cornerRadius: .containerConcentric)` / `ConcentricRectangle` / `Capsule`,curvature 自动随容器同心,**不硬编码圆角魔数阶梯**。
4. **自截图迭代验收**:不靠猜、不靠 mock。实现后自 `screencapture` 真机截 Clipin,逐项比对,改到满意再交用户终验。

## 设计

### 单元 1 — 窗面回归整窗 Liquid Glass(`AppDelegate.swift`)

- 删除 `AppDelegate.swift:373-384` 的实心深色 `NSView surface`(`backgroundColor = srgb(0.118,0.118,0.129)`)及其 host 约束块。
- 改用 macOS 26 原生 `NSGlassEffectView` 作 `panel.contentView` 的玻璃宿主:
  - `glass.cornerRadius = ClipinChrome.shellCornerRadius`(与 panel frame `cornerRadius` KVC 同值,保持窗形同心)。
  - `glass.contentView = ClipinPanelHostingView(rootView: MainPanel(viewModel: vm))`。
  - `panel.contentView = glass`。
- **窗口行为字节不变**:`.titled + .fullSizeContentView + .nonactivatingPanel`、`cornerRadius` KVC、`hasShadow`、`backgroundColor=.clear`、`isOpaque=false`、safe-area 归零、`onResignKey`、level/collectionBehavior、键盘路由 —— 全部不动。
- 注释更新:把"单玻璃层=实心深色"那段改为记录本次方向修正的根因(实心深色被用户真机否决 → 回归整窗 Liquid Glass 导航层),保留"圆角由 panel frame KVC 统一框、不手动 masksToBounds"的旧坑提醒。
- SwiftUI `MainPanel` 根视图**不**加任何 `.background(...)`(沿用现状),仅保留 shell 圆角 `clipShape`。

### 单元 2 — 内容直接坐玻璃,无不透明盒子(`MainPanel.swift` / `PreviewPane.swift`)

- 主面板内容层(列表区、预览 contentStage/metadata)**不得**用 `ClipinContentSurface`(不透明实色面)把内容从玻璃上抬走。沿用 v2 单元 2 的结论:文本/媒体直接坐玻璃,靠 `ClipinInk` 语义色 + 系统 vibrancy 保证可读。
- 媒体呈现框(图片预览框、文件/网站图标块、颜色色块、placeholder orb)按 v2 Option A **保留**,非"容器套娃",不删。
- 校验门:`grep ClipinContentSurface Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift` 期望 0;`struct ClipinContentSurface` 本体保留(辅助窗口仍依赖)。

### 单元 3 — iOS 26 同心圆角系统(`ClipinTheme.swift` 为主)

**这是用户两次强调的重点("圆角矩形的弧度一定要想清楚,按最新 iOS 26")。**

iOS/macOS 26 Liquid Glass 圆角铁律,逐条落地:

- **唯一硬编码** = `ClipinChrome.shellCornerRadius`(窗壳)。它必须等于 `NSGlassEffectView.cornerRadius` 且等于 panel frame `cornerRadius` KVC —— 三处同源同值,这是窗形物理约束,不可同心化。沿用现值 24(macOS 26 launcher 量级合理;真机验收时若偏差再调此**单一** token)。
- **所有嵌套玻璃/选中形状改用同心 API**,curvature 随容器自动推导,**删除 `ClipinChrome` 里 section/card/search/row/metadata/stage 等硬编码圆角阶梯魔数**(它们正是"内外角弧不同心"返工的根因):
  - 容器内并入窗壳几何的玻璃面 → `RoundedRectangle(cornerRadius: .containerConcentric)` 或 `ConcentricRectangle`(随 `containerShape` 推导)。
  - 单行紧凑控件 / 命令胶囊 / hover 派生胶囊 / 键帽 → `Capsule(style: .continuous)`(iOS 26 玻璃按钮默认形;真机 Raycast 底栏即此族)。
  - 列表选中底板 → 同心 `RoundedRectangle`,相对列表内容区 inset 同心。
- **角统一 `style: .continuous`(squircle),禁止 `.circular`。**
- `containerShape(...)` 在每个玻璃容器根部声明一次,子形状用 `.containerConcentric`,保证"内角弧 = 外角弧 − inset"恒成立,改 shell 一处全联动。
- 保留 `ClipinChrome.shellGap`(8pt 单一间距 token)等**间距**节奏(非圆角),不在本单元动。
- **API 核验前置(CLAUDE.md:不凭文档断言而未核代码)**:`ConcentricRectangle` / `RoundedRectangle(cornerRadius: .containerConcentric)` / `containerShape` 的确切签名与可用性,实现阶段必须先对当前 Xcode SDK 编译验证(写一处最小用例编过),再全量铺开;若该 SDK 版本 API 形态不同,以 SDK 实际为准调整封装,但"单源 shell + 同心推导、零硬编码阶梯"的目标不变。

### 单元 4 — 底栏:单玻璃簇 + hover 上方派生胶囊(`MainPanel.swift` + 新组件)

- 底栏收口为单个 `GlassEffectContainer`(已是,沿用),内含:
  - 左:命令面包屑玻璃胶囊(选中显来源 app 图标+名,无选中回退 `Clipboard History`)—— `Capsule` + `.glassEffect(.regular)`。
  - 右:`Paste to {app}` 主动作 + `Actions ⌘K` —— `Capsule` + `.glassEffect(.regular.interactive())`(interactive 提供 macOS 26 原生 hover 内缩高亮 + press,不手搓)。`Paste` 是唯一 CTA,accent 仅此一处。
  - 静息态对齐真机 Raycast:**fill 极暗极克制,只露极细 rim**;不调亮磨砂。
- **新建 hover 上方派生组件**(取代现有 `isFooterHovered` 横向展开簇 / `commandCluster`):
  - 行为:hover 某底栏玻璃控件 → 在其**正上方**派生该控件的次级动作为**独立玻璃 `Capsule` 胶囊**(可多颗纵向堆叠),每颗显 `动作名 + 快捷键键帽`;鼠标移开收起。无箭头、留小缝、同款暗玻璃。
  - 映射(主):hover `Paste` → 上方派生 `⇧↵ 纯文本` / `⌥H HTML` / `⌥R RTF`(随 `selectedRepresentationUTIs` 动态;原 `pastePlainSelected` / `pasteRepresentationSelected` 行为字节不变,仅呈现位置从"Paste 左侧横排"改"Paste 正上方派生")。这是本模型的**主用途且唯一必做项**。
  - 左侧面包屑**消歧**:Clipin 的面包屑只表来源 app,无 Raycast `About Menu` 那种真实次级动作 —— **没有就不造**(CLAUDE.md #7 不兜底/不造无意义入口)。仅当后续确有面包屑级次级动作时才接同一派生机制;本次不为对称而硬塞。
  - 派生胶囊也在 `GlassEffectContainer` 体系内,系统融合;`ClipinMotion.commandReveal` 进出,克制(Apple "let glass rest in steady states")。
  - 键盘路由不变:键盘用户走全局快捷键,不依赖此 hover 派生;派生层纯鼠标可发现性增强。
- 删除手绘 accent 实色块(沿用 v2 单元 3:无 `Circle().fill(accentColor)` / `RoundedRectangle().fill(accentColor)` / `strokeBorder(accentColor)`;accent 仅 `Paste` 经 interactive 玻璃自身承载)。

### 单元 5 — 玻璃面上的可读性 / 选中态(B 方向最易翻车点)

- 列表行、预览文本直接坐 Liquid Glass 上:文字色统一走 `ClipinInk`,靠系统 vibrancy。
- 选中态沿用单层中性填充 `ClipinSelectionInk.fill`,但**玻璃面比实心深色面更难压选中对比** —— 这是**自截图迭代验收的首要项**:截真机图确认"选中行单一可辨、任意时刻不会糊成多行选中、hover 弱于选中、文字在玻璃上清晰";不达标只允许在**不引入盒子/描边**前提下微调 `ClipinSelectionInk.fill` / `ClipinHoverInk.fill` 不透明度,**绝不**回退加不透明盒子(那正是 v1 错误)。

## 自截图迭代验收(用户明确要求:不靠猜)

构建:
```
./scripts/build-rust.sh && xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build
```

自检环路(每轮):
1. 杀旧进程 → 启动新构建产物 → 用全局快捷键(CLAUDE.md:⌘⇧V)呼出主面板(Clipin 亦 LSUIElement,但 `screencapture` 已验证可绕合成层过滤抓到)。
2. `screencapture -x` 抓真屏 → 裁剪放大 Clipin 面板。
3. 逐项核查(真机像素为准):
   - ① 整窗是连续 Liquid Glass(非实心深色、非桌面穿透脏透);列表/预览/搜索直接坐玻璃无盒子。
   - ② 圆角:窗壳—底栏簇—胶囊—键帽—选中底板逐层**同心**,无内外角弧错位;角为 continuous squircle。
   - ③ 底栏静息 = 暗克制单玻璃簇 + 极细 rim,对齐真机 Raycast(非亮磨砂大板)。
   - ④ hover Paste/面包屑 → **正上方**派生独立玻璃胶囊提示次级快捷键;无箭头、留缝、同款暗玻璃;移开收起。
   - ⑤ 选中行单一可辨,玻璃面上文字清晰,任意时刻不多行选中。
   - ⑥ 5 辅助窗口(设置/引导/权限/更新)未被牵连。
4. 有问题 → 改代码 → 重编译 → 重截 → 直到全部达标。
5. 达标后交 Codex 无偏见复审(CLAUDE.md),再交用户**真机终验**。

## 非目标(明确不做,控范围)

- **面板尺寸固定 800×540 不变**:不做随内容伸缩(Raycast 剪贴板亦固定;动态 resize 是大范围 NSPanel frame 动画 + 布局重排,用户未要求,风险/范围都不值)。
- 不动窗口行为/键盘路由/连续粘贴/Quick Look/IME/辅助窗口分流(同 v2 非目标)。
- 不改 ViewModel 数据流、搜索/排序/分页 SQL 语义。
- borderless 搜索保留(无玻璃框,字节不变)。
- `struct ClipinContentSurface` 本体保留(辅助窗口依赖);仅主面板不调用。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 整窗 `NSGlassEffectView` 又透出桌面/终端=脏(v2 实心深色的初衷) | `NSGlassEffectView` 是 macOS 26 原生导航层玻璃(非旧 `.popover`/`.behindWindow` vibrancy),Spotlight/Raycast 同款;自截图验收 ①;不达标在玻璃参数内调,不回退实心盒 |
| 底栏玻璃簇 vs 窗面玻璃 = glass-on-glass | 同 `GlassEffectContainer` 簇由系统融合,Apple 文档化的控件玻璃浮导航玻璃模式;自截图验收 ③④ + Codex 专查 |
| 同心圆角 API 使用不当致 curvature 仍错位 | 删硬编码阶梯、`containerShape`+`.containerConcentric` 单源;自截图验收 ② 逐层比对 |
| 选中态在玻璃面对比不足 | 自截图验收 ⑤ 首要项;只在无盒/无描边前提微调 ink 透明度 |
| mock 与真机材质差 | 已固化教训:**不用 mock 验材质**;唯一口径自截图真机像素 + 用户终验 |

## 文件影响面

- `Clipin/App/AppDelegate.swift` — 单元 1:实心 `NSView surface` → `NSGlassEffectView`;注释更新。
- `Clipin/App/ClipinTheme.swift` — 单元 3:删硬编码圆角阶梯魔数,改同心 API 体系;`ClipinFooterGlassButtonStyle` 形状收口为 `Capsule`;选中底板同心化。保留 `shellCornerRadius` / `shellGap` / `ClipinInk` / `ClipinSelectionInk`。
- `Clipin/Views/MainPanel.swift` — 单元 2:确认无 `ClipinContentSurface`;单元 4:`bottomBar` hover 模型从横向展开改"上方派生玻璃胶囊",新组件;同心圆角接入。
- `Clipin/Views/PreviewPane.swift` — 单元 2:确认无 `ClipinContentSurface`;同心圆角接入(媒体框保留)。
- 新增组件文件(单元 4 hover 派生胶囊),命名实现计划阶段定。
- 不改:`SearchBar.swift`、辅助窗口四件、ViewModel、Services、Rust。
