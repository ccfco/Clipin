# ⌘K 动作面板：动画与体验优化设计

## 背景与问题

Clipin 的 ⌘K 动作面板（`ActionPalette`）是 launcher 的全局命令入口。当前实现存在几个体验问题，都是读代码可证实的事实，而非主观感觉：

1. **入场动画名不副实**。`MainPanel` 给面板套的入场过渡是 `.scale(scale: 0.985)`——只缩放 1.5%，肉眼几乎不可见。所谓「入场」实际被 opacity 淡入主导，面板像是「凭空出现在右下角」，没有「从 ⌘K 按钮长出来」的实感。

2. **`paletteScale` / `paletteLift` 是死代码**。`ActionPalette` 内部还有一套基于 `ClipinSceneState` 的缩放/位移动画，但这个视图是条件插入的——它出现时 `isShowingActions` 已是 `true`，`paletteScale`/`paletteLift` 一开始就是终态值，这套内部动画永远不会触发。

3. **退场只有 opacity 淡出**。面板「飘走」而非「收回」，缺少收束感。

4. **面板与底栏割裂**。面板用 `padding(.bottom, floatingFooterBand + shellGap)` 悬浮在底栏上方，和底栏两个按钮（「粘贴到 Claude」「动作 ⌘K」）之间没有视觉关联，更不像「从 ⌘K 按钮展开的命令簇」。

5. **滚动条闪烁 bug**。面板开启时主列表和预览区会闪现 overlay 滚动条。根因：`isShowingActions` 翻转时，主列表被加 `.scaleEffect(0.998)`、预览区被加 `previewScale`——这 0.2% 的缩放肉眼不可见，但 macOS overlay 滚动条只要 ScrollView 的 bounds 发生变化就会闪现一次。微缩放是「看不见效果、只留副作用」的死重。

6. **信息层次单薄**。面板头部只有死板的「Actions」字样；分组之间只靠空白间距，没有分隔线。

7. **没有高度上限**。所有 action 行平铺在 `VStack` 里，没有 `ScrollView`、没有 `maxHeight`。条目较多的选中项（带 HTML/RTF representation actions）会让面板无限长高。

8. **悬浮感不足**。面板只有 native `glassEffect` 的发丝 rim，没有落影，不像「浮」在内容之上。

## 目标

让 ⌘K 面板的开启/关闭像 Raycast 一样「从右下角 ⌘K 按钮长出 / 收回」，盖住底栏；同时修掉滚动条 bug、补上信息层次、高度上限和悬浮感。**参照 Raycast 的手感，但保留 Clipin 自己的视觉语法**（统一的 surface/玻璃/键帽语言、无内建搜索框的静态命令表心智）。

## 非目标（明确排除）

- **不做选中游标的连续滑动**（`matchedGeometryEffect`）。理由：主列表（`粘贴项`）的选中也是逐行交叉淡入淡出，全代码库无 `matchedGeometryEffect`。面板的选中表现必须和主列表保持一致——主列表不做，面板就不做。面板选中沿用现有的逐行淡入淡出。
- **不做 action 行的逐行级联出现**。面板行随面板整体一次性出现即可。
- **不加回内建搜索框**。动作面板是静态命令表，这是既有决策，本次不动。

## 设计

### ① 入场 / 退场动画——从 ⌘K 按钮长出、盖住底栏

**定位**：面板从「悬浮在底栏上方」改为右下角与底栏玻璃胶囊**外接角重合**。
- `ActionPalette` 中面板的定位 padding 改为 `.padding(.trailing, shellGap * 2)`（= 16，对齐底栏胶囊右缘）、`.padding(.bottom, shellGap)`（= 8，落到窗口底边距）。
- 底栏 `bottomBarRow` 用的就是 `.padding(.horizontal, shellGap * 2)` + `.padding(.bottom, shellGap)`，因此面板右下角与底栏玻璃胶囊外接角精确重合，无需读取按钮 anchor。
- 面板宽度保持 372，圆角保持 `paletteCornerRadius`（26）。

**入场**：
- 过渡 = `.scale(scale: 0.90, anchor: .bottomTrailing)` 叠加 `.opacity`。
- 0.90 的缩放下，372 宽的面板左上角起始时内收约 37pt，配合 `.bottomTrailing` 锚点，读起来就是「从右下角那颗按钮长出来」。
- 弹簧：新增 `ClipinMotion.paletteReveal = .spring(response: 0.30, dampingFraction: 0.80)`——带一点生气，不过弹。

**退场**：
- 过渡 = `.scale(scale: 0.93, anchor: .bottomTrailing)` 叠加 `.opacity`。
- 弹簧：新增 `ClipinMotion.paletteDismiss = .spring(response: 0.20, dampingFraction: 0.92)`——快、不回弹、收得干脆。
- 入场与退场需要不同弹簧，因此面板开关由 `ClipboardViewModel` 中切换 `isShowingActions` 的位置用显式 `withAnimation(ClipinMotion.paletteReveal)` / `withAnimation(ClipinMotion.paletteDismiss)` 驱动，而不是用 `.animation(_:value:)` 修饰符（后者无法区分插入/移除）。

**底栏同步淡出**：
- 面板展开时 `bottomBar` 的 opacity 同步 1→0，并 `.allowsHitTesting(false)`。
- 淡出的两个理由：① 面板玻璃是半透的，底栏的亮胶囊会从面板边缘透出；② opacity 为 0 的视图默认仍接收点击，不关掉 hit testing 会点到面板下方的幽灵按钮、并可能误触发 `showsDerivedPills` 派生簇。
- 关闭时底栏 opacity 同步 0→1 淡回。

### ② 面板信息层次

**头部上下文**：
- 有选中项时，头部从死板的「Actions」换成「类型图标 + 条目标题」（单行截断），右侧保留 `Esc` 键帽——对应 Raycast 头部的「Image (1642×1112)」。
- 无选中项时（空历史 / 纯全局命令场景）回退显示「Actions」。
- `ActionPalette` 当前不接收选中项信息，需新增头部描述参数（标题字符串 + 可选 SF Symbol 图标名），由 `MainPanel` 从 `viewModel.selectedListItem` 计算后传入。

**分组分隔**：
- primary / secondary / destructive 三组之间，用 1px hairline divider（低透明度的 `ClipinInk`，左右内缩约 12pt）替代当前的纯空白间距，让层次更清楚。

### ③ 最大高度 + 条目滚动

- 面板设最大高度 ≈ **460pt**（窗口高 540 − 顶部搜索区呼吸位 ~72 − 底边距 8）。
- action 行区域包进内层 `ScrollView`；**头部固定、不参与滚动**。结构为 `VStack { header（固定）; ScrollViewReader { ScrollView { 行 } } }`。
- `ScrollViewReader` 跟随 `selectedIndex`：键盘 ↑↓ 移动选中时，把选中行 `scrollTo` 进可见区，游标不会滑出视野。每行需带 `.id(index)`。
- 行数不超过最大高度时，`ScrollView` 自然不出现滚动条，面板按内容高度收缩。

### ④ 悬浮感

- 面板在 `clipinChromeGlass` 之外再加一层显式落影：`.shadow(radius: 28, y: 14)`，透明度 light ≈ 0.22 / dark ≈ 0.40。
- native `glassEffect` 只给发丝 rim、不给落影。底栏淡出后右下角不再有第二层玻璃胶囊，这层落影能干净地独立成立，面板真正「浮」在内容之上。

### ⑤ 滚动条 bug 修复 + 死代码清理（根因修复）

- **删除** 主列表 `itemList` 上的 `.scaleEffect(isShowingActions ? 0.998 : 1.0)`，以及预览区 `PreviewPane` 上的 `previewScale` 缩放——这两处对「含 ScrollView 的视图」做的不可见微缩放，正是滚动条闪烁的根因。
- **保留** `listRestingOpacity`（面板开启时主列表压暗到 0.965）：这 3.5% 的压暗是可见的焦点收束，且 opacity 变化不改变 ScrollView 的 bounds、不触发滚动条闪烁。
- **删除死代码**：`ClipinSceneState.paletteScale` / `paletteLift` 及其在 `ActionPalette` 中的 `.scaleEffect` / `.offset` 调用。
- **底栏**：原 `stripScale`（0.997，不可见微缩放）随底栏改为 opacity 淡出而一并移除。

## 受影响文件

- `Clipin/Views/ActionPalette.swift`——面板定位 padding、入场/退场过渡、头部上下文、分组 hairline divider、最大高度、内层 `ScrollView` + `ScrollViewReader`、删除 `paletteScale`/`paletteLift` 调用。
- `Clipin/Views/MainPanel.swift`——传入头部上下文参数、删除 `itemList` 的 `scaleEffect`、底栏 opacity 淡出 + `allowsHitTesting`、删除 `stripScale` 用法。
- `Clipin/Views/PreviewPane.swift`——删除 `previewScale` 缩放。
- `Clipin/App/ClipinTheme.swift`——新增 `ClipinMotion.paletteReveal` / `paletteDismiss`；从 `ClipinSceneState` 删除 `paletteScale` / `paletteLift` / `stripScale`。
- `Clipin/ViewModels/ClipboardViewModel.swift`——切换 `isShowingActions` 处改用显式 `withAnimation`（区分 reveal / dismiss 弹簧）。

## 边界与一致性

- **键盘路由不变**：↑↓ / Return / Esc 仍由 `AppDelegate.keyMonitor` 在 palette 开启时拦截。新增的内层 `ScrollView` 不得引入自己的键盘语义，滚动只由 `ScrollViewReader` 跟随 `selectedIndex` 被动触发。
- **空态**：无选中项时面板只有全局动作，头部回退「Actions」，最大高度/滚动逻辑照常。
- **destructive 行**：「删除」行的红色选中填充沿用现有 `ClipinSelectableRowBackground` 逻辑，逐行淡入淡出不变。
- **派生簇**：底栏淡出并关闭 hit testing 后，`showsDerivedPills`（hover Paste 浮出的次级动作簇）在面板开启期间自然不会触发。
- **`reduced motion`**：`ClipinMotion.reduced` 既有降级路径不变；新增的两个弹簧 token 在降级场景沿用既有处理方式。

## 测试

- Rust 侧无改动，无需 `cargo test`。
- 手动验证（构建 Release 后自截图 / 实操）：
  1. ⌘K 开启：面板从右下角 ⌘K 按钮处缩放展开、盖住底栏，底栏两按钮同步淡出。
  2. Esc / 点空白关闭：面板向右下角收回、底栏淡回。
  3. 开启与关闭瞬间：主列表与预览区**不再闪现滚动条**。
  4. 选中带多个 representation actions 的图片/文件条目，确认面板高度不超过上限、行区域可滚动，↑↓ 把选中行滚进可见区。
  5. 头部显示当前选中条目的类型图标 + 标题；空历史下显示「Actions」。
  6. 分组之间有 hairline 分隔线；面板有可见落影、浮在内容之上。
  7. 键盘 ↑↓ / Return / Esc 行为与改动前一致。
