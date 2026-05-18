# Clipin 主面板优雅化 —— 对齐 Raycast / macOS 26(减法重构)

- 日期:2026-05-18
- 状态:设计已确认(用户对整体 mock「对了」),待用户审阅规格
- 基线:`feat/liquid-glass-migration` @ `5bb3228`(Liquid Glass 迁移已完成,本次在其上继续打磨,同分支,不单独并 main)
- 触发背景:迁移完成后与 Raycast 剪贴板历史并排对比,确认 Clipin「优雅」差距不在材质(原生玻璃已落地),而在**构图克制度**——Clipin 一直在加 chrome,Raycast 的优雅来自减 chrome。

## 目标

把 Clipin 主面板从「加 chrome 的密集工具」减成「一整块安静连续面」的原生 launcher,与 Raycast / macOS 26 的克制审美一致:层级靠留白 + 极淡中性 + 材质深度表达,不靠边框/胶囊/玻璃叠玻璃;accent 稀用;底部 chrome 以真·液态玻璃悬浮于内容之上,视觉上不存在「底栏条」。

### 核心理念(本 spec 的统一原则)

**优雅 = 减法。** 每个改动单元都在「删 chrome / 收信号 / 用结构代替画线」,不新增装饰。

### 非目标(本 spec 明确不做)

- 不改 `ClipinChrome` 布局骨架的**尺寸 token**(insets / heights / cornerRadius 数值)。本次只动材质、形状、选中信号、底部悬浮结构;搜索去框是删背景不是改尺寸。
- 不动窗口行为:`.nonactivatingPanel`、panel `cornerRadius` KVC、safe-area 归零、`.titled + .fullSizeContentView`。
- 不动键盘路由:AppDelegate key monitor、↑↓ / Return / Esc 分层回退 / Tab / ⌥0-5 / Space 预览、IME preedit 拦截。
- 不动连续粘贴逻辑、Quick Look session、辅助窗口(设置/引导/权限/更新)的功能与窗口分流。
- 不动预览元数据胶囊条的**数据层与胶囊形态**(用户明确喜欢,保留)。
- 不改搜索框的 key-intercept / IME 协调逻辑(字节级不变,只去其玻璃背景)。

## 硬约束:不兜底 / 不遗留(承接迁移 spec + CLAUDE.md #7)

- 被删 chrome(底栏长条玻璃、搜索玻璃框、选中 accent rail/描边/加粗/变色、预览条上方发丝线)**彻底删除**,不留 compat / fallback / "以防万一" 死代码。
- 不写 `@available` 兜底分支(已 26+ only)。
- 选中态的「rail 退役」是**修根因**(列表区改不透明面)后的自然结果,不是「先留着以防万一」。异常/缺失值暴露,不 `try?` 吞、不占位兜底。
- 不遗留 = 无悬空引用 + 无半转换态:被删符号全仓引用 100% 清完,不允许「一部分新、一部分旧」进主干。

## 设计

### 单元 A —— 列表选中减重 + accent rail 退役(修根因)

**根因分析**:accent rail 当年是为「半透明玻璃上多行看起来同时选中」打的补丁。Raycast 不需要 rail,是因为它的列表坐在**不透明安静面**上,多行不会彼此晕开。真正的根因解法不是保留 rail,而是消除「列表坐在半透明面」这个根因。

- **列表区改为不透明安静面**:列表内容区使用近实色中性背景(`ClipinContentSurface` 量级,不透明),不再让行坐在可透视玻璃上。根因消除后,单一极淡中性选中填充即可清晰区分,不会出现「多行同时选中」错觉。
- **删除全部冗余选中信号**:`ClipinSelectableRowBackground` 的选中态 rail capsule(`isSelected && showsSelectionAccent` 分支)与选中描边 overlay 删除;`ClipItemRow` 文字 `weight: isSelected ? .semibold` → 恒 `.medium`,`foregroundStyle: isSelected ? .accentColor` → 恒 `ClipinInk.primary`,typeIndicator 选中态 accent 前景/accent 阴影删除。
- **选中态 = 单一极淡中性圆角填充,且明确强于 hover**:`ClipinSelectionInk.fill` 由 `accentColor.opacity(0.18)` → 中性 `Color.primary.opacity(~0.07)`;同时 `ClipinHoverInk.fill` 由 `0.06` 调淡到 `~0.035`,建立清晰强弱次序(选中 > hover),没了 rail 后仅靠这一层中性填充即可区分选中/hover/默认三态。叠加既有根因机制(选中变化清空 `hoveredID`)防 hover 残留成第二选中态。`ClipinSelectionInk.stroke`/`.dim`/`.highlight` 中 accent 用法一并收敛为中性,仅搜索命中 `.highlight` 可保留极淡 accent。
- **D1(已确认):改全局 token**。`ClipinSelectionInk` 是主列表 + 动作面板 + 设置侧栏共用 token,本次改全局,使三处一致变克制(符合 CLAUDE.md「共享选中语法」),不只改主列表造成各面板长出不同皮肤。
- **行内容化**:`ClipItemRow` 的 `trailingMeta`(⌘N + 时间戳)不再在每行常驻。
  - **⌘1-9 可发现性张力(需用户在规格审阅时确认)**:CLAUDE.md 有决策「⌘1-9 已经在列表行右侧表达」「全局命令入口要持续可发现」。完全移除会让 ⌘1-9 失去唯一可发现点。**本规格的折中**:`trailingMeta` 仅在「该行为当前选中行」时显示(hover 不显示,保持滚动时绝对干净);用户上下移动选中时,选中行始终显示其 ⌘N + 时间戳,既维持 Raycast 级干净(任意时刻只有 1 行有元数据),又不丢 ⌘1-9 可发现性。若用户审阅时要求"彻底不显示",再改为完全移除并接受可发现性退化。

### 单元 B —— macOS 26 悬浮液态玻璃底部(无底栏条)

- **删整条底栏玻璃**:`MainPanel.bottomBar` 外层 `.clipinChromeGlass(cornerRadius: sectionCornerRadius)`(满宽长条 + 内部胶囊再叠玻璃 = 玻璃套玻璃)删除。无底栏条、无任何分隔线。
- **内容铺满全高**:列表 + 预览不再为 footer 预留 `footerMinHeight` 高度;`bottomBar` 从 VStack 流式布局改为 `.overlay(alignment: .bottom)` 浮层。内容延伸到窗口最底,悬浮玻璃覆盖其上。
- **底部 = 离散半透明液态玻璃元件**(`.glassEffect(.regular, in:)`,原生即半透明,内容从玻璃后淡淡透出):
  - **左:source 面包屑胶囊**。D2(已确认):显示选中项来源 app —— 彩色 `sourceAppIcon` + `sourceName`;无选中时回退 `Clipboard History` + Clipin 字形。`.glassEffect(.regular, in: Capsule)`。
  - **右:Paste / Actions 软圆角玻璃组**。单个 `.glassEffect(.regular, in: RoundedRectangle)` 容器,内含两段:`Paste to {targetApp}` + 主键帽 `↵`(此处保留 accent —— 全窗唯一强调点)| 细分隔 | `Actions` + 键帽 `⌘K`。hover 辅助命令簇(HTML/RTF/Plain/Open/Preview)与连续粘贴 pill 行为不变,重新归位到该悬浮布局中(各自独立玻璃元件,不再套在长条里)。
- **悬浮遮挡防护(修根因,不打补丁)**:内容铺满全高会让悬浮玻璃永久遮住最后一行/预览底部 —— 这是真实可用性 bug,不接受。解法:列表滚动容器 + 预览内容追加 `底部 content inset = 悬浮玻璃外接高度 + 间距`,使滚到底时最后一项能停在玻璃**上方**可达;滚动途中的中间项从半透明玻璃后透出(macOS 26 / iOS 26 悬浮 tab bar 安全区同款语义)。视觉「内容在玻璃后」与可用「最后一项可达」二者同时成立。
- 本单元同时恢复并升级 CLAUDE.md 原始决策「底栏是透明 command area,只让独立胶囊各自承担材质」(迁移时被糊回长条,已退化);现进一步做到内容在悬浮玻璃后流动,符合真·macOS 26 习语。

### 单元 C —— 搜索:borderless inline(去框)

- 删 `SearchBar` 外层 `.clipinChromeGlass(cornerRadius: searchCornerRadius)` 玻璃框。搜索 = glyph + 输入直接坐在连续面上,无任何 box/胶囊/玻璃背景(Raycast ①)。
- glyph 去掉 `Circle().fill(controlColor)` 衬底圆,改纯 inline SF Symbol;清除按钮简化为轻量 inline。
- `filterChip` 保留在搜索栏内右侧(键盘 Tab/⌥0-5 路由不动,S3「移出搜索栏」方案已否决),仅去 chrome 变轻量。
- `InterceptingTextField` / Coordinator / IME preedit / syncBindingText / doCommandBy 全部**字节级不变**。

### 单元 D —— 预览面板:保留,仅去一条发丝线

- 预览元数据横滚胶囊条(`PreviewFooterRail`)用户明确喜欢:**胶囊形态与 `footerEntries / *Badge` 数据层完全保留**。
- 唯一改动:删除 `PreviewFooterRail` 顶部 `.overlay(alignment:.top){ Rectangle().fill(...0.10).frame(height:0.6) }` 那条 0.6pt 发丝线。分隔改由**抬起的预览卡(`ClipinContentSurface(elevated:true)` 的圆角 + 投影边界)本身**承担——结构即分隔,不画线。
- 胶囊条降为「卡内安静注脚」:维持 `ClipinInk.secondary`、无 `emphasis` 时不带 accent、填充更淡,使其在抬起卡内**退**,与基面上**进**的悬浮 footer 形成深度区分(不抢)。预览内容卡维持 `elevated:true`。

### 单元 E —— 配色克制

- accent(蓝)全窗仅保留**一处真正强调**:右下 Paste 主键帽。其余(选中、图标、次级文字、filter)一律中性灰。
- 该收敛大部分由单元 A 的 `ClipinSelectionInk` 全局中性化达成;单元 B/C/D 不得重新引入 accent 装饰。

## 验证方式(可执行,对应「不遗留」)

构建:

```
./scripts/build-rust.sh                    # 不受影响
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
  -destination 'generic/platform=macOS' build
```

构建必须**零警告**涉及被删符号,不允许半转换态进主干。

无悬空引用门(grep,期望全部为 0):

```
# 底栏长条玻璃 / 搜索玻璃框已删(bottomBar、SearchBar 容器级不再 wrap 玻璃)
grep -rn "showsSelectionAccent" Clipin/ --include='*.swift' | wc -l            # 期望 0(rail 退役,参数与分支全删)
grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l                # 期望 0(无兜底门)
```

视觉逐项核查:

1. 全窗无底栏条、无任何分隔线
2. 底部 source 面包屑 + Paste/Actions 是半透明液态玻璃,内容从玻璃后淡淡透出
3. 滚到底时最后一行/预览底部可达,不被悬浮玻璃永久遮挡(悬浮遮挡防护生效)
4. 选中 = 单一极淡中性填充,无 rail/加粗/变色/描边;在已转不透明的列表面上,任意时刻不会出现"多行同时选中"错觉(根因修复验证)
5. 搜索无框,glyph+文字直接坐面上
6. 预览胶囊条除去顶部发丝线外原样;读作卡内安静注脚,不与底部 footer 抢
7. accent 仅出现在右下 Paste 主键帽
8. 动作面板 + 设置侧栏选中态随 `ClipinSelectionInk` 全局 token 一致变克制(D1)
9. 行只有图标+文字;⌘N+时间戳仅当前选中行显示(可发现性折中)
10. 5 窗口/辅助窗口未被牵连(本次主面板范围,设置/引导/权限/更新走标准控件,确认未退化)

回归核查(不应受影响,需确认未被牵连):

- 键盘导航 / 类型筛选 / Esc 分层回退 / Tab 循环 / ⌥0-5 / Space 预览
- 连续粘贴夺焦恢复、`.nonactivatingPanel` 行为
- Quick Look session 浏览
- IME 实时搜索(preedit)

收尾:按 CLAUDE.md,实现完成后交 Codex 做一次无偏见 review,重点查边界与遗留(尤其单元 B 的悬浮遮挡 inset 计算、单元 A 的 rail 退役全仓清理)。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 列表转不透明面后,选中仅靠极淡中性是否仍不可混淆 | 核查项 #4 专项;选中清空 hoveredID(沿用既有根因修复)防 hover 残留成第二选中态 |
| 悬浮玻璃永久遮住最后一行(可用性 bug) | 单元 B「悬浮遮挡防护」:content 底部 inset = 玻璃高度 + 间距;核查项 #3 验收 |
| ⌘1-9 失去可发现性(与 CLAUDE.md 决策冲突) | 折中:仅当前选中行显示 ⌘N+时间戳;规格审阅时由用户最终确认是否可接受 |
| rail 退役不彻底,残留 `showsSelectionAccent` 悬空 | grep 门强制为 0;Codex 复审专查 |
| D1 改全局 token 牵连动作面板/设置侧栏视觉 | 这是预期且符合「共享选中语法」;核查项 #8 确认三处一致而非各异 |

## 文件影响面

- `Clipin/App/ClipinTheme.swift` —— `ClipinSelectionInk`(fill→中性、accent 用法收敛)、`ClipinSelectableRowBackground`(删 rail capsule + 选中描边)、列表区不透明面承载。
- `Clipin/Views/ClipItemRow.swift` —— 删选中加粗/变色/图标 accent/阴影;`trailingMeta` 改为仅当前选中行显示。
- `Clipin/Views/MainPanel.swift` —— `bottomBar`:删容器级玻璃长条;改 `.overlay(alignment:.bottom)` 离散半透明玻璃元件(左 source 面包屑 / 右 Paste|Actions 组);内容全高 + 底部 content inset 防遮挡;source 面包屑(D2)。
- `Clipin/Views/SearchBar.swift` —— 删玻璃框;glyph 去衬底圆;filterChip 去 chrome;key-intercept/IME 逻辑字节不变。
- `Clipin/Views/PreviewPane.swift` —— `PreviewFooterRail` 删 0.6pt 顶部发丝线;胶囊条降为安静注脚;数据层与胶囊形态保留。
