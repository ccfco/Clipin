# Clipin 迁移到原生 Liquid Glass(单 native 主题)

- 日期:2026-05-18
- 状态:设计已确认,待生成实施计划
- 触发背景:对比 Raycast(macOS 26 Tahoe,原生 Liquid Glass)后确认 Clipin 的 chrome 全是手绘玻璃,即使跑在 Tahoe 上也永远不会获得系统 Liquid Glass,设计语言停留在旧时代。

## 目标

把 Clipin 全部 5 个窗口的 chrome 从「手绘玻璃模拟」迁移到 macOS 26 原生 Liquid Glass,使其与系统设计语言一致。首版只跑通**单一 native 无 tint 主题**,用于验证「纯系统材质能否托住这个密集型工具 App」这一前提;多主题 tint 推迟。

### 非目标(本 spec 明确不做)

- 不做 4 主题的 tint 调色与映射(`VisualTheme` 推迟,见第 5 节)。
- 不解决 PreviewFooterRail 横向滚动可发现性问题(独立议题,不在本次范围)。
- 不重排布局骨架:`ClipinChrome` 的圆角/间距 token 及其承载的 CLAUDE.md 决策保持不变。
- 不改窗口行为(`.nonactivatingPanel`、键盘路由、连续粘贴、Quick Look 等)。

## 关键决策(已与用户确认)

1. **最低系统 macOS 26+**:部署目标从 15.0 提到 26.0,放弃 Sequoia 用户。**全程不写 `@available` 双轨。**
2. **纯原生 Liquid Glass**:删除手绘玻璃体系,玻璃只有 `.glassEffect(.regular)` 一个变体,首版不接 tint。
3. **一次性全 5 窗口换**:主面板 / 设置 / 引导 / 权限 / 更新提醒,单 spec 单 plan。
4. **首主题 = native 无 tint**:验证纯系统材质基准线。
5. **架构走路线 C**:薄语义封装 `ClipinGlass` + 仅在玻璃聚集处用 `GlassEffectContainer`。

## 硬约束:不兜底 / 不遗留(用户明确强调)

遵循 CLAUDE.md 编码原则 #7。在本次迁移中具体落实为:

- **不留兼容兜底**:`ClipinGlassPalette` 等被删类型**彻底删除**,不保留为 fallback / compat shim / "以防万一" 的死代码。
- **不写 `@available` 兜底分支**:已是 26+ only,任何 `if #available(macOS 26...)` 都属于多余兜底,禁止出现。
- **VisualTheme 塌缩是显式决策,不是静默 default**:4 个 case 必须**显式**解析为同一个原生玻璃,代码与注释表达「主题已推迟、当前显式渲染 native glass」,而非「不支持就 fallback 到默认」。设置页主题选择器**隐藏**,不留「选了没反应」的无效 UI。
- **异常暴露而非消化**:玻璃形状/参数计算所需的值若缺失,直接报错或让其可见地失败,不加 `try?` 吞、不加占位兜底。(注:`PreviewPane` 既有的 "Image not found" 等是内容态 UI,非错误兜底,不在改动范围,保持原样。)
- **不遗留 = 无悬空引用 + 无半转换态**:被删符号在全仓的引用点必须 100% 转换完(见第 6 节量化清单),不允许出现「一部分窗口新玻璃、一部分旧玻璃」的中间态残留进主干。

## 设计

### 1. 部署目标与 SDK

- `project.yml` 第 5 行 `deploymentTarget.macOS: "15.0"` → `"26.0"`;若 target 级 `settings.base` 有 `MACOSX_DEPLOYMENT_TARGET` 同步;之后 `xcodegen generate` 重新生成 `.xcodeproj`。
- 编译环境已是 Xcode 26.5 / macOS SDK 26.5,Liquid Glass API 直接可用。
- 核查 `Info.plist` / `project.yml` info 段**不得**含 `UIDesignRequiresCompatibility`(该 key 会主动退出 Liquid Glass)。
- 现状 `@available(macOS` 引用数为 0,无历史版本门需要清理。

### 2. 删手绘玻璃,建薄封装 `ClipinGlass`

`Clipin/App/ClipinTheme.swift` 处置表:

| 现有类型 | 引用点 | 处置 |
|---|---|---|
| `ClipinGlassPalette` | 26 | 删除 |
| `ClipinSurfaceBackground` | 21 | 删除,调用点改 `ClipinGlass` modifier |
| `ClipinSurfaceStyle` | 10 | 删除 |
| `ClipinPanelHierarchy` | 19 | 大幅塌缩:前景改系统语义色,自动 vibrancy |
| `ClipinShellBackground` | 5 | 删除(外壳玻璃移交 SwiftUI 根 container) |
| `ClipinSurfaceRole` | 5 | 塌缩为二元语义(chrome/content),不再是 8-case enum |
| `ClipinRoundedSurface` | 3 | 删除 |
| `surfaceStyle(for:)` ~100 行映射 | 2 | 删除 |
| `NSVisualEffectView` | 3 | 删除(见第 3 节) |
| `ClipinChrome`(圆角/间距 token) | — | **保留**,玻璃形状用其圆角做 `in: RoundedRectangle(cornerRadius:)` |
| `ClipinSelectableRowBackground`(选中 accent rail) | — | **保留逻辑**(CLAUDE.md 根因修复),fill/stroke 改语义色 |
| `ClipinKeycap` / `ClipinSymbolOrb` | — | 重表达为玻璃原件 |

新增 `ClipinGlass`(极薄):

- `.chromeGlass(in: shape)` → 内部 `.glassEffect(.regular, in: shape)`,**单一可调缝**,集中承载「玻璃只用于 chrome」红线与日后 tint 接入点。
- content 面:不上玻璃,用近实色中性背景(系统 `.background` / `Color(nsColor: .controlBackgroundColor)` 量级),保证文字在玻璃外壳之上仍清晰。
- `ClipinPanelHierarchy` 前景 ink 改用 `.primary` / `.secondary` / `Color(nsColor: .tertiaryLabelColor)`,由系统在玻璃上自动做 vibrancy,不再手算。

### 3. NSPanel chrome 重做(全方案最高风险)

CLAUDE.md 原决策「panel chrome AppKit 自管 + `NSVisualEffectView(.popover)` + 不自绘边 + 不裁圆角防发丝线叠加」的改写:

- **保留**:`.titled + .fullSizeContentView + .nonactivatingPanel`、隐藏标题栏/交通灯、SwiftUI safe-area 归零、不抢 key。这些是窗口行为,与材质无关,继续有效。
- **替换**:删除 `NSVisualEffectView` 整套 panel chrome(3 处);玻璃改由 SwiftUI 根部单个 `GlassEffectContainer { content }.glassEffect(.regular, in: RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius))` 提供。窗口 `isOpaque = false`、`backgroundColor = .clear`、不自绘边、不 `masksToBounds`。
- **为何根治旧踩坑**:旧双发丝线来自「NSVisualEffectView 抗锯齿边 + NSWindow frame + 自裁圆角」三者叠加;三者全部移除后,系统玻璃形状自身即窗口边,边缘高光由系统绘制,叠加源消失。
- **实施顺序约束**:此节**第一个**做,完成后立即截图验证面板边缘(无双线、无顶空/底叠),通过后才继续其它窗口;不通过则不推进。
- 辅助窗口沿用 CLAUDE.md「原生 titled 窗 vs borderless 小浮层」分流,仅替换材质实现:titled 窗在 26 上标准 chrome 自动采用 Liquid Glass;borderless 小浮层根部 `.glassEffect`。

### 4. 5 窗口玻璃映射

**主面板**(`MainPanel` / `PreviewPane` / `SearchBar` / `ActionPalette` / `ClipItemRow`):

- 外壳:根 `GlassEffectContainer` + `.glassEffect(.regular, RoundedRectangle(shellCornerRadius))`
- 搜索栏:glass 圆角(chrome)
- 侧栏列表区:**不上玻璃**,实色中性面;行用 `ClipinSelectableRowBackground`(语义色),选中 accent rail 保留
- 预览 contentStage / metadata:**不上玻璃**,实色面,保留 14/12 圆角层级;contentStage 靠 shadow 维持「浮起」语义
- 底栏:`GlassEffectContainer` 包 Paste CTA + Actions + 命令胶囊使其融合;CTA `.buttonStyle(.glassProminent)`,其余 `.glass`
- badge / keycap / orb:glass 胶囊

**设置 / 引导 / 权限 / 更新提醒**:标准控件 26 上自动采用;各自定义 `ClipinSurfaceBackground` 面 → 导航 chrome 上玻璃、内容区实色;symbol orb → glass。

设计红线:列表行、预览正文显式排除玻璃(Apple 官方:玻璃属 chrome,内容坐其上)。这是约束不是选项。

### 5. VisualTheme 塌缩(推迟,不破坏编译)

- `VisualTheme` 枚举保留可编译;`SettingsStore.visualTheme` 属性保留(不破坏持久化/迁移)。
- 4 个 case 渲染结果显式 = 同一个 native 无 tint 玻璃(措辞见「硬约束」节:显式决策,非静默 default)。
- 设置页主题选择器隐藏/禁用,不留死 UI。

### 6. 验证方式(可执行,对应「不遗留」)

构建:

```
./scripts/build-rust.sh                    # 不受影响
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
  -destination 'generic/platform=macOS' build
```

无悬空引用门(grep,期望全部为 0):

```
grep -rn "ClipinGlassPalette\|ClipinSurfaceBackground\|ClipinSurfaceStyle\|ClipinRoundedSurface\|ClipinShellBackground\|surfaceStyle(" Clipin/ --include='*.swift' | wc -l   # 期望 0
grep -rn "NSVisualEffectView" Clipin/ --include='*.swift' | wc -l                                                                                                              # 期望 0
grep -rn "@available(macOS" Clipin/ --include='*.swift' | wc -l                                                                                                                # 期望 0(无兜底门)
```

构建必须**零警告**涉及被删符号;不允许半转换态进主干。

视觉逐项核查:

1. 玻璃只出现在 chrome,列表/预览正文坐实色面、文字清晰
2. 面板边无双发丝线、无顶部空隙/底部重叠(直击旧踩坑)
3. 底栏胶囊经 `GlassEffectContainer` 融合
4. 选中 accent rail 在玻璃上仍不可混淆(CLAUDE.md 根因修复未退化)
5. 5 个窗口逐个截图核对,无一处残留旧玻璃

回归核查(chrome 不应影响,但需确认未被牵连):

- 键盘导航 / 类型筛选 / Esc 分层回退
- 连续粘贴夺焦恢复、`.nonactivatingPanel` 行为
- Quick Look session 浏览

收尾:按 CLAUDE.md,实现完成后交 Codex 做一次无偏见 review,重点查边界与遗留。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| NSPanel 改写后边缘出现新发丝线/裁切异常 | 第 3 节最先做,单独截图验收后才推进 |
| 玻璃叠到内容区导致文字糊 | 第 4 节红线:列表行/预览正文显式实色,核查项 #1 |
| 89 处引用点半转换残留 | 第 6 节 grep 门强制全 0,零警告 |
| 选中态在玻璃上变模糊(退化 CLAUDE.md 根因修复) | 核查项 #4 专项验证 accent rail |
| 提到 26.0 后既有 API 行为变化 | 现状无 `@available`,改动以材质为主,回归核查覆盖窗口行为 |

## 文件影响面

`Clipin/App/ClipinTheme.swift`(主战场,删+建)、`Clipin/App/AppDelegate.swift`(NSPanel chrome)、`Clipin/Views/` 下 MainPanel / PreviewPane / SearchBar / ActionPalette / ClipItemRow / SettingsView / OnboardingView / PermissionView / UpdateReminderView / ShortcutRecorder、`project.yml`(部署目标)。
