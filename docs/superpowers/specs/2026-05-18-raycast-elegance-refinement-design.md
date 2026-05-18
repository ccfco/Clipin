# Clipin 主面板原生化 —— 对齐 macOS 26 Liquid Glass / Raycast(结构纠正)

- 日期:2026-05-18
- 状态:**v2 结构纠正**,方向已与用户确认(选「结构纠正」),待用户审阅本规格
- 基线:`feat/liquid-glass-migration`,在已落地的 6 个优雅化 commit(`aa38306`…`8193b16`)之上做结构纠正(不回退、不并 main)

## 修订记录(决策留痕,CLAUDE.md:记录关键决策)

- **v1(已被用户视觉否决)**:5 单元减法重构。实现并通过两阶段复审 + Codex 复审 + 全量门后,用户真机验收判定「太丑、完全不原生」。
- **v1 失败的真正根因(Apple 文档 + 代码双向印证,非凭印象)**:Apple 对 macOS 26 的硬规则是 **Liquid Glass 只属于"导航/控件层",内容永远是实底铺在最底、玻璃浮在内容之上**("content sits at the bottom, glass controls float on top";"reserved for the navigation layer, not for main content")。v1 把这条反过来:`MainPanel.swift:33` 把**整个窗口外壳**包进 `.glassEffect`,玻璃落到了内容层;为在玻璃上保持可读,列表/预览被**迫各自套不透明 `ClipinContentSurface` 盒子**。用户讨厌的"大框/容器/底栏不原生"是同一个根因的三个症状——**玻璃放错了层**。v1 spec 删了底栏与搜索的玻璃,却从未删外壳玻璃,反而把内容盒子写成了"为可读性保留",institutionalize 了错误。
- **v2 纠正方向**:把玻璃从内容层移除,回到 Apple 的原生分层。这是去掉**一个**错误结构决策 + 它逼出来的补偿盒子,不是堆补丁(CLAUDE.md #6),也不需要全部回退(骨架/borderless 搜索/轻高亮选中本来就对)。
- **教训固化**:涉及 macOS 26 材质的方案,HTML mock 只能定布局**不能定材质**(mock 用 `backdrop-filter` 近似,真 `.glassEffect` 的厚度/边缘高光/投影完全不同),材质验收必须以真机截图为准。

## 目标

把主面板做成 **macOS 26 原生 launcher**:一块连续 vibrant 实底铺满窗口,列表行与预览内容**直接坐在实底上、无任何内层盒子**;唯一的 Liquid Glass 是底部那一簇悬浮命令控件,作为导航层浮在内容之上。形态对齐 Raycast / Spotlight(它们正是"vibrant 实底 + 内容直接铺 + 底部浮起控件"),材质对齐 Apple macOS 26 Liquid Glass 规范。

### 核心原则

**玻璃只在控件层,内容层永远是连续实底,内容直接坐其上、不套盒子。** 每个改动单元都服务这一条。

### Apple 官方规范交叉核对(已验证,2026-05-18)

本 spec 每个决策已逐条对照 Apple HIG《Materials》/《Liquid Glass》技术文档 + WWDC25 + 专业参考核对:

| Apple 明文规范 | 出处 | 本 spec 对应 |
|---|---|---|
| "Liquid Glass is exclusively for the navigation layer that floats above content";"Never apply to content itself (lists, tables, media)" | HIG / 技术文档 | 单元 1+2:外壳玻璃删除、内容盒子全删 ✅ |
| "controls sit on top of a **system material**, not directly on content. Without that separation, contrast can suffer" | HIG Materials | **保留 NSVisualEffectView 为 system material 分隔层**——这是 Apple 强制要求,非"待删盒子"(见单元 1 强约束)✅ |
| "Glass cannot sample other glass;container provides shared sampling region" → 必须 `GlassEffectContainer` | 技术文档 | 单元 3:底栏归一为单个 `GlassEffectContainer` ✅ |
| `.glassProminent` = 不透明、承载 tint,用于 primary;`.glass`/regular = 半透明,用于 secondary;tint 仅 CTA、不装饰 | 技术文档 | 单元 3 + accent 收敛:Paste=`.glassProminent`(accent 的原生落点),其余 regular 中性 ✅ |
| 玻璃元件圆角用 `RoundedRectangle(cornerRadius: .containerConcentric)` 与容器同心,不硬编码 | 技术文档 | 单元 3:底栏玻璃元件同心圆角(本次新增;单元 1 的 shell `clipShape` 是窗形裁剪非玻璃元件,不适用)✅ |
| "let glass rest in steady states";勿过度动效 | 常见错误清单 | 强约束新增"动效克制"条 ✅ |
| 无障碍(Reduce Transparency / Increase Contrast)由系统对原生 `.glassEffect` **自动**降级,开发者不手动处理 | 技术文档 | 强约束澄清:"不兜底"≠ 关掉系统无障碍适配;不写手动 fallback、也不强制 `.identity` ✅ |

### 非目标(明确不做)

- 不动窗口行为:`.nonactivatingPanel`、panel `cornerRadius` KVC、safe-area 归零、`.titled + .fullSizeContentView`、AppKit 层 `NSVisualEffectView` 的存在与挂载方式。
- 不动键盘路由:AppDelegate key monitor、↑↓ / Return / Esc 分层回退 / Tab / ⌥0-5 / Space 预览、IME preedit 拦截。
- 不动连续粘贴逻辑、Quick Look session、辅助窗口(设置/引导/权限/更新)功能与窗口分流。
- 不动预览元数据横滚胶囊条的**数据层与胶囊形态**(用户明确喜欢,保留;仅去掉它的外层盒子,让它直接坐在实底上)。
- 不改搜索框 key-intercept / IME 协调逻辑(字节级不变;borderless 在 v1 已做对,保留)。
- 不改键盘导航语义、不改 ViewModel 数据流。

## 硬约束:不兜底 / 不遗留(CLAUDE.md #7)

- 被删结构(外壳 `.glassEffect` / **主面板内容层**的 `ClipinContentSurface` 调用点 / 底栏手绘 accent 实色块)**彻底删除**,不留 compat / fallback / 死代码。
- 不写 `@available` 兜底分支(已 26+ only)。
- 不遗留 = 无悬空引用 + 无半转换态:主面板内删除的调用点 100% 清完(`MainPanel.swift` / `PreviewPane.swift` 内不再出现 `ClipinContentSurface`),不允许"一部分新一部分旧"进主干。**注意**:`struct ClipinContentSurface` 本体及辅助窗口调用点是预期保留,**不是**遗留——区分"主面板退役"与"struct 全删"。
- 异常/缺失值暴露,不 `try?` 吞、不占位兜底。
- **无障碍澄清(Apple 验证)**:原生 `.glassEffect` 在 Reduce Transparency / Increase Contrast / Reduce Motion 下由系统**自动**降级,开发者不写手动适配。本 spec 的"不兜底"指**不写业务 fallback**,**绝不**等于关闭/覆盖系统无障碍适配——不得为了"统一外观"加 `.accessibilityReduceTransparency` 判定后强制 `.identity` 或自绘替代;系统行为原样保留即正确。
- **动效克制(Apple "let glass rest in steady states")**:本次**不新增**任何动效。现有 `sceneState` 的 `selectedRowScale / selectedRowLift / listRestingOpacity / stripScale / headerLift` 等缩放/位移/整列变透明动效,在原生玻璃语境下属"过度动效"的非原生风险点,列为 **Codex 收尾 + 真机验收观察项**;但本次范围是结构纠正,**不主动重构动效**以免扩大范围,除非用户在验收时明确要求再单独立项。

## 设计(3 个结构纠正单元 + 明确保留项)

### 单元 1 —— 去外壳玻璃,窗口回到连续 vibrant 实底(根因修复)

- 删除 `MainPanel.body`(`MainPanel.swift:24-37`)的 `GlassEffectContainer { … }.glassEffect(.regular, in: RoundedRectangle(shellCornerRadius))` 外壳玻璃包裹。`MainPanel` 根视图不再自带任何玻璃/背景。
- 窗口底层材质由**已存在的 AppKit 层 `NSVisualEffectView`(`.popover` material,见 CLAUDE.md 决策)**单独承担——这正是 Raycast/Spotlight 的 vibrant 实底。不在 SwiftUI 层新加任何 `.background(...)`、不新建替代 surface(避免重新长出"外壳"或不透明盒子)。
- **`NSVisualEffectView` 是 Apple 强制要求的"system material 分隔层",绝不可删**:Apple HIG 明文"controls sit on top of a system material, not directly on content"。底栏玻璃簇与其后内容之间正是靠这层 system material 保证对比度/可读性。它不是单元 2 要删的"内容盒子",删它会直接违反 Apple 规范且 contrast 崩坏。实现者必须区分:删的是 SwiftUI **内容层**的玻璃/盒子,保的是 AppKit **窗口层**的 system material。
- `panelContent` 仍按 shell 圆角 `clipShape`(保留圆角窗形,这与玻璃层无关),但不再有 `.glassEffect`。圆角值沿用 `ClipinChrome.shellCornerRadius`(窗形裁剪,非玻璃元件,不适用 `.containerConcentric`)。

### 单元 2 —— 删掉所有内容盒子,内容直接坐实底

- **列表**:删除 `MainPanel.swift:130-134` `itemList.background(ClipinContentSurface(cornerRadius: sectionCornerRadius))`。列表行直接坐在窗口 vibrant 实底上,无 292pt 不透明大框。
- **预览(用户已定 Option A:去文本块底、留媒体框)**:删除 `PreviewPane` 的 3 处 `ClipinContentSurface`——`:52` 包裹整预览的 `elevated:true` 大卡、`:543` `supportingBlock`(OCR/文件路径文本块底)、`:1025` `urlInfoBlock`(Full URL / Query 文本块底)。文本内容与横滚胶囊条直接坐实底,**无背景容器、无投影抬起卡**。
  - **明确保留(媒体呈现,非容器,本次不动)**:`mediaCanvas`(图片预览框,`PreviewPane.swift:513-526`)、文件图标块(`:136-143` `ZStack` + `RoundedRectangle(controlColor)`)、`FaviconView` 图标框(`:874-892`)、`ColorSwatchPreview` 色块(`:623-633`)、`placeholder` orb(`:486-493`)。这些是媒体/图标呈现,Raycast 预览同样有框,**不属"容器套娃",实现者不得顺手删**。
- **`ClipinContentSurface` 仅从主面板内容层移除,struct 本体保留**:`ClipinContentSurface` 还被辅助窗口共用——`SettingsView`(3)、`UpdateReminderView`、`PermissionView`(2)、`OnboardingView`。那些是本次**非目标、未被否、属标准 macOS grouped 面**的窗口,绝不牵连。本单元只删**主面板内容层**的调用点:`MainPanel.swift:131`(列表 box)、`PreviewPane.swift:52`(包裹整预览的 `elevated:true` 大卡)、`PreviewPane.swift:543`(`supportingBlock`:OCR/文件路径文本块底)、`PreviewPane.swift:1025`(`urlInfoBlock`:Full URL / Query 参数块底)。**`struct ClipinContentSurface` 本体不删**(辅助窗口仍依赖)。grep 门相应收窄(见验证)。
- 选中态(Q2 已锁:Raycast 式轻高亮)现在直接坐在 vibrant 实底上。`ClipinSelectionInk.fill` 维持 v1 的中性极淡圆角填充,但需在真机 vibrant 实底上**仍清晰可辨**(验收项专项);hover 仍弱于选中;选中变化清空 `hoveredID` 防残留(沿用既有根因机制)。不画描边、不画整块容器,背景贴内容不贴满宽(`listRowOuterInset` gutter 保留)。

### 单元 3 —— 底栏归一为单个原生 Liquid Glass 簇

- 现状缺陷(`MainPanel.swift:171-396`):底栏是 5 个独立块拼盘——`sourceBreadcrumb`(`clipinChromeGlass` 胶囊)、hover 命令簇(另一 `clipinChromeGlass` 胶囊)、Paste CTA(`.glassProminent` 里又手绘 `Circle().fill(Color.accentColor)` 图标底)、`continuousPastePill`(**非玻璃**:手绘 `RoundedRectangle.fill(Color.accentColor.opacity(0.18))` + `strokeBorder`)、Actions(又一 `clipinChromeGlass` 胶囊)。玻璃 + 手绘 accent 实色块混排 → 不原生。
- **改为单个 `GlassEffectContainer`** 包裹底栏命令簇(Apple 规范:"group multiple glass elements within a GlassEffectContainer";glass 不能采样 glass,必须同容器内由系统统一融合)。容器内:
  - 左:`sourceBreadcrumb` —— 选中显来源 app(彩色 `sourceAppIcon` + `sourceName`),无选中回退 `Clipboard History`;`.glassEffect(.regular, in: Capsule)`。
  - 右:`Paste to {targetApp}` 用 `.buttonStyle(.glassProminent)`。Apple 验证:`.glassProminent` 本就是**不透明、自带 tint** 的 primary-action 玻璃——这正是 accent 唯一原生落点,**删掉内部手绘 `Circle().fill(accentColor)`**,只留 label + 键帽 `↵`,强调由 prominent 玻璃自身承载,不再手绘。`Actions ⌘K` 用 regular `.glassEffect`(半透明,secondary 语义)。
  - hover 辅助命令簇(HTML/RTF/Plain/Open/Preview)、连续粘贴态:行为/键盘路由不变,但**一律改用真 `.glassEffect`**,删除 `continuousPastePill` 与 `keyBadge(emphasized:)` 的手绘 `RoundedRectangle.fill(Color.accentColor…)`+`strokeBorder` 实色块。连续粘贴**激活态**统一在玻璃簇内用 **regular `.glassEffect` + 系统 tint**(`.tint(...)`)表达——**不用 `.glassProminent`**:按 Apple"tint 仅 CTA"+ 本 spec"accent 仅 Paste",prominent 是唯一 CTA(Paste)的专属,连续粘贴态是模式指示不是 CTA,再上 prominent 会出现两个强调点稀释唯一性。**绝不**手绘 accent 矩形(去掉 v1 的"或自绘"歧义:只允许原生玻璃表达)。
  - **同心圆角(Apple 验证)**:底栏玻璃簇/各玻璃元件的圆角,凡与 shell 底部圆角发生视觉关系处,用 `RoundedRectangle(cornerRadius: .containerConcentric)`(或 Capsule 自然同心),不硬编码半径数值,保证与窗形同心对齐——这是 macOS 26 明文做法。具体形状由实施计划按布局确定,但"不硬编码、用 concentric"是硬要求。
- **遮挡语义(沿用 v1 选项 A 思路,去掉抬起卡框)**:底栏玻璃簇 `.overlay(alignment:.bottom)` 浮在内容上。① 左列表滚动容器底部 `safeAreaInset = 玻璃簇外接高度 + 间距`,保证滚到底最后一行停在玻璃簇**上方**可达;② 右预览内容(含横滚胶囊条)底部留 `bottom padding = 玻璃簇外接高度 + 间距`,胶囊条**永远完整在玻璃簇上方**、横滚发现区全程可见可交互。两区共用单一度量常量(`ClipinChrome.floatingFooterBand` 已存在,沿用)防漂移。区别于 v1:此遮挡留白靠 padding/inset 实现,**不靠任何 elevated 盒子**。

### 明确保留(v1 中本来就对的,不动)

- **borderless 搜索**(原单元 C):`SearchBar` 无玻璃框、glyph+输入直接坐面上、`InterceptingTextField`/IME 字节不变 —— 保留。
- **Raycast 式轻高亮选中**(Q2 锁定):中性极淡圆角填充、无 rail/描边/加粗/变色 —— 保留,仅验证其在 vibrant 实底上的可辨性。
- **横滚胶囊条数据 + 胶囊形态**:`footerEntries / *Badge` 数据层与胶囊外观保留,仅脱掉外层盒子。
  - **已知并刻意保留的例外(诚实记录)**:`PreviewValueBadge`(`PreviewPane.swift:713`)的胶囊用 `.clipinChromeGlass(in: Capsule)` = 真 `.glassEffect`,即"内容区里有玻璃小胶囊"。这与本 spec 核心原则"玻璃只在控件层"相抵,但**用户多次明确要求横滚胶囊条原样不动**——按指令优先级(用户指令 > 规范推导),这是**用户优先的有意例外**,不是 spec 违规。Codex/复审/真机验收**不得**以"内容区有玻璃"判它不合规;它脱掉外层 `ClipinContentSurface` 大卡后,直接浮在 `NSVisualEffectView` system material 上(玻璃采样 system material,非 glass-on-glass),可接受。
- **accent 收敛**(原单元 E):全窗 accent 仅余 Paste 主键帽语义(由 `.glassProminent` 表达),其余中性。

## 验证方式(可执行;材质验收以真机为准)

构建(必须零警告涉及被删符号):

```
./scripts/build-rust.sh
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
  -destination 'generic/platform=macOS' build
```

无悬空引用门(grep,期望全部为 0):

```
grep -rn "ClipinContentSurface" Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift | wc -l   # 期望 0(主面板内容层调用点删净;struct 本体与辅助窗口调用点预期保留,不在此门)
grep -rn "showsSelectionAccent" Clipin/ --include='*.swift' | wc -l            # 期望 0(v1 已退役,保持)
grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l                # 期望 0(无兜底门)
grep -rn "Circle()" Clipin/Views/MainPanel.swift | wc -l                       # 期望 0(Paste 内手绘 accent 圆删净;当前仅此一处 Circle)
grep -rn "strokeBorder(Color.accentColor" Clipin/Views/MainPanel.swift | wc -l # 期望 0(底栏手绘 accent 描边块删净)
```

> 注:不设 `accentColor.opacity == 0` 这种宽门——`MainPanel.swift:48` 顶部连续粘贴 2pt 渐变指示线合法使用 `Color.accentColor.opacity(0.4)`,不在本次范围,宽门会假阳性。底栏手绘 accent 实色块的清净由上面两条精确门 + Codex 收尾专查(底栏不得有任何 `RoundedRectangle().fill(Color.accentColor…)` / `strokeBorder(Color.accentColor…)` 手绘块)+ 真机视觉项 #3 共同保证。

视觉逐项核查(**真机截图为准,mock 不算验收**):

1. 窗口是一块连续 vibrant 实底;列表行直接坐其上无 292pt 大框;预览**无包裹整体的 `ClipinContentSurface` 大卡、无 OCR/URL/Query 文本块底**,文本直接坐实底。媒体框(图片预览框/文件·网站图标块/颜色色块/placeholder orb)按 Option A **预期保留**,不算违规。
2. 唯一玻璃 = 底部命令簇,作为一个内聚整体浮在内容上(不是 5 个拼块,不是玻璃叠玻璃)。
3. 底栏无手绘 accent 实色方块/圆;Paste 的强调来自 `.glassProminent` 自身,不是手绘 Circle。
4. 选中 = 单一极淡中性填充,在 vibrant 实底上仍清晰可辨,无 rail/描边/加粗/变色;任意时刻不会"多行同时选中"。
5. borderless 搜索:无框,glyph+文字直接坐面上(保持 v1)。
6. 横滚胶囊条:形态/数据原样,但不再被盒子包裹,直接坐实底,作为安静注脚不与底部玻璃簇抢。
7. 遮挡:① 列表滚到底最后一行可达;② 预览横滚胶囊条永远完整在玻璃簇上方、横滚区全程可交互。
8. accent 仅余 Paste 主键帽语义。
9. 动作面板/设置侧栏选中态随 `ClipinSelectionInk` 全局 token 一致(D1 沿用)。
10. 5 窗口/辅助窗口未被牵连。
11. **(Apple 规范)** 底栏玻璃元件圆角与 shell 同心(`.containerConcentric`/Capsule),无硬编码半径错位;`NSVisualEffectView` system material 分隔层仍在(未被当盒子误删),玻璃↔内容对比度正常;Reduce Transparency 开启时由系统自动加重 frosting(未被代码覆盖)。

回归核查(不应受影响,需确认未被牵连):

- 键盘导航 / 类型筛选 / Esc 分层回退 / Tab / ⌥0-5 / Space 预览
- 连续粘贴夺焦恢复、`.nonactivatingPanel`
- Quick Look session、IME 实时搜索(preedit)

收尾:实现完成后交 Codex 无偏见 review,重点查:主面板 `ClipinContentSurface` 调用点是否清净(`struct` 本体与辅助窗口调用点为**预期保留**,不得误删)、底栏 `GlassEffectContainer` 归一后无手绘 accent 残留、遮挡 inset 计算、外壳玻璃删除后无悬空背景引用、**NSVisualEffectView system material 未被误删**、**玻璃元件圆角是否用 `.containerConcentric` 而非硬编码**、**无障碍适配未被代码覆盖**。**最终以用户真机视觉验收为准,不达标不并 main(绝不带病合并)。**

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 去掉内容盒子后,文字直接坐 vibrant 实底可读性下降 | 这是 Raycast/Spotlight 同款标准做法;可读性由 `NSVisualEffectView` material 选择 + 语义 `ClipinInk` 文字色保证,**绝不**用重新加不透明盒子来"修"(那正是 v1 错误);核查项 #1/#4 真机专项 |
| 选中极淡中性在 vibrant 实底上不够可辨 | 核查项 #4 真机专项;必要时在不引入盒子/描边前提下微调 `ClipinSelectionInk.fill` 不透明度,仍为单层中性填充 |
| 底栏 `GlassEffectContainer` 归一后 hover 辅助簇/连续粘贴态布局错乱 | 行为/键盘路由字节不变,仅换材质与容器归并;核查项 #2/#3 + 回归核查;Codex 专查 |
| `ClipinContentSurface` 退役不彻底,残留悬空引用 | grep 门强制为 0;Codex 复审专查 |
| mock 与真机材质差再次误导验收 | 已固化教训:mock 不作材质验收;唯一验收口径是用户真机截图 |

## 文件影响面

- `Clipin/App/ClipinTheme.swift` —— **`ClipinContentSurface` struct 本体保留不删**(辅助窗口仍依赖);仅当选中态可辨性需要时微调 `ClipinSelectionInk.fill` 不透明度,否则本文件可不改。
- `Clipin/Views/SettingsView.swift` / `UpdateReminderView.swift` / `PermissionView.swift` / `OnboardingView.swift` —— **不改**(`ClipinContentSurface` 在此为标准 grouped 面,本次非目标)。
- `Clipin/Views/MainPanel.swift` —— 单元 1:删外壳 `GlassEffectContainer`+`.glassEffect`;单元 2:删 `itemList` 的 `ClipinContentSurface` background;单元 3:`bottomBar` 归一为单个 `GlassEffectContainer`,删 `pasteCallToAction` 内手绘 `Circle().fill(accentColor)`、删 `continuousPastePill`/`keyBadge(emphasized:)` 手绘 accent 实色块。
- `Clipin/Views/PreviewPane.swift` —— 删所有 `ClipinContentSurface`(contentStage/metadata/elevated 抬起卡);横滚胶囊条数据/形态保留,脱盒直接坐实底;遮挡留白靠 bottom padding。
- `Clipin/Views/SearchBar.swift` —— **不改**(borderless 已对,字节不变)。
- `Clipin/Views/ClipItemRow.swift` —— 仅在选中态可辨性需要时受 `ClipinSelectionInk` 影响,结构不改。
