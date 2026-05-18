# Clipin 主面板原生化 v2 实施计划(结构纠正)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。每任务 fresh subagent + 两阶段复审(先 spec 合规、再代码质量)。步骤用 `- [ ]`。

**Goal:** 把玻璃从内容层移除、删主面板内容盒子、底栏归一为单个原生 Liquid Glass 簇,使主面板成为 macOS 26 原生 launcher(对齐 Raycast/Spotlight + Apple HIG)。

**Architecture:** 三个结构纠正单元,严格按 spec `docs/superpowers/specs/2026-05-18-raycast-elegance-refinement-design.md` v2。顺序 Task1→2→3,每任务独立 commit、独立可构建。基线分支 `feat/liquid-glass-migration`,在 6 个 v1 优雅化 commit + spec commit 之上。

**Tech Stack:** SwiftUI + AppKit(macOS 26 only),`.glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glassProminent)`。Rust 不涉及。

**验证模型(本仓现实,不可造假):** 仓库**无 SwiftUI 单测框架**(测试仅 Rust)。每任务验证 = `xcodebuild` Release **零警告** + grep 门 + 结构断言(对照本计划目标代码),然后 commit。**绝不**伪造 XCTest。真机视觉验收是用户的、最后做,不在任务内。

**全局硬约束(每任务都适用,违反即不合规):**
- 不兜底 / 不写 `@available` / 不 `try?` 吞错。
- 不动:键盘路由、IME preedit、连续粘贴逻辑、Quick Look、窗口行为、ViewModel 数据流、辅助窗口(Settings/Onboarding/Permission/Update)。
- 不新增动效(Apple "let glass rest in steady states");现有 `sceneState` 动效本次不重构。
- `struct ClipinContentSurface` 本体**保留不删**(辅助窗口依赖);只删主面板内容层调用点。
- 行为/hover/键盘/transition 逻辑**字节级不变**,本次只改材质/容器/形状。

**构建命令(各任务通用):**
```
./scripts/build-rust.sh
xcodegen generate
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build
```
期望:`** BUILD SUCCEEDED **`,无新增 warning。

---

## 文件结构

- `Clipin/Views/MainPanel.swift` —— Task1(body 去外壳玻璃)、Task2(itemList 去 box)、Task3(bottomBar 归一 + 去手绘 accent)。
- `Clipin/Views/PreviewPane.swift` —— Task2(3 处 ClipinContentSurface 删除,媒体框保留)。
- 其余文件不改。

---

## Task 1：单元 1 —— 去外壳玻璃,窗口回 NSVisualEffectView vibrant 实底

**Files:**
- Modify: `Clipin/Views/MainPanel.swift:23-37`(`var body`)

- [ ] **Step 1：替换 `body`,删除外壳 `GlassEffectContainer` + `.glassEffect`**

当前(`MainPanel.swift:23-37`):
```swift
    var body: some View {
        GlassEffectContainer {
            // .glassEffect(in:) 不裁剪子视图，AppKit host 又 masksToBounds=false，
            // 全宽 top 渐变/notice/ActionPalette overlay 会冲出 24pt 圆角 shell。
            // 先按 shell 形状裁掉内容+overlay，再让 GlassEffectContainer 渲染 shell 玻璃材质。
            panelContent
                .clipShape(
                    RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
                )
        }
        .glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
        )
    }
```

改为:
```swift
    var body: some View {
        // 内容层不上玻璃(Apple HIG:Liquid Glass 只属导航/控件层,内容须实底)。
        // 窗口底材质由 AppKit 层 NSVisualEffectView(.popover,见 CLAUDE.md / ClipinPanelChromeView)
        // 单独承担——这是 Apple 要求的 system material 分隔层,绝不在 SwiftUI 再加背景。
        // 仍按 shell 圆角裁剪,保证全宽 top 渐变/notice/ActionPalette overlay 不冲出圆角窗形。
        panelContent
            .clipShape(
                RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
            )
    }
```

- [ ] **Step 2：构建,确认零警告**

Run 构建命令。期望:`** BUILD SUCCEEDED **`,无新增 warning。
（注:此时 footer 仍是分散 `clipinChromeGlass`,无 GlassEffectContainer,属过渡态,Task3 收口;真机观感非此任务验收点。）

- [ ] **Step 3：结构断言**

Run: `grep -n "GlassEffectContainer\|\.glassEffect(" Clipin/Views/MainPanel.swift`
期望:输出中 **`var body` 区段(23-30 行附近)不再出现** `GlassEffectContainer` 或 `.glassEffect(`(footer 的 `clipinChromeGlass` 是 extension 调用,不在此 grep 命中,属正常)。`body` 仅 `panelContent.clipShape(...)`。

- [ ] **Step 4：commit**

```bash
git add Clipin/Views/MainPanel.swift
git commit -m "refactor: 单元1 去外壳玻璃 —— 玻璃移出内容层回 NSVisualEffectView 实底

【根因/背景】v1 把整窗外壳包进 .glassEffect 致玻璃落到内容层(根因)。
按 Apple HIG '内容须实底、玻璃只在控件层' 删除外壳 GlassEffectContainer
+.glassEffect,窗口底材质交还 AppKit 层 NSVisualEffectView system material。
【踩坑记录】clipShape 必须保留(全宽 top 渐变/notice/overlay 防冲出圆角)。
【改动范围】MainPanel.swift var body:删外壳玻璃,仅留 panelContent.clipShape。"
```

---

## Task 2：单元 2 —— 删主面板内容盒子(Option A:去文本块底、留媒体框)

**Files:**
- Modify: `Clipin/Views/MainPanel.swift:130-134`(itemList background)
- Modify: `Clipin/Views/PreviewPane.swift:46-58`(contentStage)、`:528-547`(supportingBlock)、`:1011-1029`(urlInfoBlock)

- [ ] **Step 1：MainPanel itemList 去 `ClipinContentSurface` 大框**

当前(`MainPanel.swift:128-136` 内 itemList 段):
```swift
            itemList
                .frame(width: 292)
                .background(
                    ClipinContentSurface(
                        cornerRadius: ClipinChrome.sectionCornerRadius
                    )
                )
                .scaleEffect(sceneState.isShowingActions ? 0.998 : 1.0)
                .opacity(sceneState.listRestingOpacity)
```
改为(删 `.background(ClipinContentSurface…)`,其余不动):
```swift
            itemList
                .frame(width: 292)
                .scaleEffect(sceneState.isShowingActions ? 0.998 : 1.0)
                .opacity(sceneState.listRestingOpacity)
```

- [ ] **Step 2：PreviewPane `contentStage` 去包裹整预览的 `elevated:true` 大卡**

当前(`PreviewPane.swift:46-58`):
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
改为(删 `.background(ClipinContentSurface…)`,**保留** padding 与 `.padding(.bottom, floatingFooterBand)` 遮挡留白):
```swift
    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, ClipinChrome.floatingFooterBand)
    }
```

- [ ] **Step 3：PreviewPane `supportingBlock` 去文本块底**

当前(`PreviewPane.swift:540-547`,`supportingBlock` 尾部):
```swift
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinContentSurface(
                cornerRadius: ClipinChrome.detailMetadataCornerRadius
            )
        )
```
改为(删 `.background(ClipinContentSurface…)`,保留 padding/frame):
```swift
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 4：PreviewPane `urlInfoBlock` 去文本块底**

当前(`PreviewPane.swift:1022-1029`,`urlInfoBlock` 尾部),与 Step 3 同形:
```swift
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinContentSurface(
                cornerRadius: ClipinChrome.detailMetadataCornerRadius
            )
        )
```
改为:
```swift
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 5：媒体框必须原样保留(不得顺手删)**

确认以下**未被改动**(Option A 用户已定:媒体呈现保留):
`mediaCanvas`(`PreviewPane.swift:513-526`)、文件图标块(`:136-143` `ZStack`+`RoundedRectangle(controlColor)`)、`FaviconView`(`:870-899`)、`ColorSwatchPreview` 色块(`:622-633`)、`placeholder` orb(`:485-493`)。这些不含 `ClipinContentSurface`,本任务不触碰。

- [ ] **Step 6：构建,确认零警告**

Run 构建命令。期望:`** BUILD SUCCEEDED **`,无新增 warning。

- [ ] **Step 7：grep 门**

```bash
grep -rn "ClipinContentSurface" Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift | wc -l   # 期望 0
grep -rn "ClipinContentSurface" Clipin/ --include='*.swift' | wc -l                                   # 期望 ≥8(struct 本体 + 辅助窗口预期保留)
```
第一条必须 `0`;第二条必须 `≥8`(证明 struct 与辅助窗口调用点未被误删)。

- [ ] **Step 8：commit**

```bash
git add Clipin/Views/MainPanel.swift Clipin/Views/PreviewPane.swift
git commit -m "refactor: 单元2 删主面板内容盒子 —— 内容直接坐实底(Option A)

【根因/背景】外壳玻璃删除后,列表/预览不再需要不透明盒子补偿可读性。
按用户 Option A:删列表 292pt 大框 + 预览包裹大卡 + OCR/URL/Query 文本
块底,文本直接坐 NSVisualEffectView 实底。
【踩坑记录】ClipinContentSurface 被辅助窗口共用,struct 本体与
Settings/Onboarding/Permission/Update 调用点必须保留(grep≥8 验证)。
媒体框(图片/图标/色块/orb)是媒体呈现非容器,Option A 明确保留。
【改动范围】MainPanel itemList 去 background;PreviewPane contentStage/
supportingBlock/urlInfoBlock 删 3 处 ClipinContentSurface。"
```

---

## Task 3：单元 3 —— 底栏归一为单个原生 Liquid Glass 簇

**Files:**
- Modify: `Clipin/Views/MainPanel.swift`：`bottomBar`(171-272 包一层 `GlassEffectContainer`)、`continuousPastePill`(325-358)、`pasteCallToAction`(369-396)、`keyBadge`(398-420)

> 约束:`bottomBar` 内所有 hover/onTap/transition/键盘相关逻辑、`sourceBreadcrumb`、`commandCluster`、各 Button action **字节级不变**,本任务只做:① 整簇包进单个 `GlassEffectContainer` ② 删 Paste 内手绘 `Circle` ③ `continuousPastePill` 改原生玻璃+tint ④ `keyBadge` 删 `emphasized` 死分支与手绘块。`sourceBreadcrumb`/`commandCluster` 已是真 `clipinChromeGlass`(=`.glassEffect`),仅随簇进容器,不改其内部。footer 元件均为 `Capsule`(天然同心),无与 shell 角关联的硬编码 `RoundedRectangle`,故本任务**不需** `.containerConcentric`;若实现中新增 RoundedRectangle 形玻璃才必须用 `.containerConcentric`。

- [ ] **Step 1：`bottomBar` 整簇包进单个 `GlassEffectContainer`**

当前结构(`MainPanel.swift:171-272`)是 `HStack(spacing: 8){…}` 后跟一串 `.padding/.frame/.onHover/.animation/.scaleEffect/.padding/.padding/.animation`。改法:在最外层包 `GlassEffectContainer`,**HStack 及其所有现有修饰符整体不动**,仅整体作为容器子视图:

```swift
    private var bottomBar: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                // …171-258 行 HStack 内全部内容,逐字不动…
            }
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
        }
    }
```
（仅新增最外层 `GlassEffectContainer { … }` 包裹,HStack 内容与其所有修饰符顺序逐字保持。GlassEffectContainer 用默认 spacing。）

- [ ] **Step 2：`pasteCallToAction` 删手绘 `Circle().fill(accentColor)` 图标底**

当前(`MainPanel.swift:369-396`):
```swift
    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                Image(systemName: "arrow.up.forward.app.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: ClipinChrome.footerCalloutIconSize, height: ClipinChrome.footerCalloutIconSize)

            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(ClipinInk.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            ClipinKeycap(
                key: key,
                foreground: ClipinInk.secondary
            )
        }
        .padding(.leading, ClipinChrome.footerCalloutHorizontalLeading)
        .padding(.trailing, ClipinChrome.footerCalloutHorizontalTrailing)
        .padding(.vertical, ClipinChrome.footerCalloutVerticalInset)
    }
```
改为(删整个 `ZStack{Circle…}`;`.glassProminent`(调用点 line 240,不在本函数,保持)自带不透明 tinted 玻璃承载强调;label 去掉显式 `ClipinInk.primary` 让 prominent 原生控制前景对比):
```swift
    private func pasteCallToAction(label: String, key: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            ClipinKeycap(
                key: key,
                foreground: ClipinInk.secondary
            )
        }
        .padding(.leading, ClipinChrome.footerCalloutHorizontalLeading)
        .padding(.trailing, ClipinChrome.footerCalloutHorizontalTrailing)
        .padding(.vertical, ClipinChrome.footerCalloutVerticalInset)
    }
```

- [ ] **Step 3：`continuousPastePill` 改原生 `.glassEffect` + 系统 tint(删手绘 accent 矩形)**

当前(`MainPanel.swift:325-358`):
```swift
    private var continuousPastePill: some View {
        Button { viewModel.toggleContinuousPaste() } label: {
            HStack(spacing: 7) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Continuous Paste")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ClipinKeycap(
                    key: "Esc",
                    foreground: Color.accentColor.opacity(0.82)
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }
```
改为(删手绘 `.background(RoundedRectangle…accent…)`,换原生 `.glassEffect(.regular.tint(...), in: Capsule)`;模式 tint 由玻璃材质承载,图标/文字/keycap 前景中性化交给 tint):
```swift
    private var continuousPastePill: some View {
        Button { viewModel.toggleContinuousPaste() } label: {
            HStack(spacing: 7) {
                Image(systemName: "repeat.circle.fill")
                    .font(.system(size: 12.5, weight: .semibold))

                Text("Continuous Paste")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                ClipinKeycap(
                    key: "Esc",
                    foreground: ClipinInk.secondary
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(Color.accentColor), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Press Esc to exit Continuous Paste.", comment: ""))
        .accessibilityLabel(Text("Continuous Paste"))
        .accessibilityHint(Text("Press Esc to exit Continuous Paste."))
    }
```
> 若 `Glass.regular.tint(_:)` 在当前 SDK 不可用导致编译失败:**报错暴露、停下来上报**(不兜底、不换手绘 fallback),由控制者决定换 `.glassEffect(.regular, in: Capsule).tint(Color.accentColor)` 形式后再续。

- [ ] **Step 4：`keyBadge` 删 `emphasized` 死分支 + 手绘块**

`emphasized:true` 在全仓无任何调用点(所有调用为 `keyBadge(label:key:)`),是死路径。当前(`MainPanel.swift:398-420`):
```swift
    private func keyBadge(label: String, key: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(emphasized ? Color.accentColor : ClipinInk.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ClipinKeycap(
                key: key,
                foreground: emphasized ? Color.accentColor.opacity(0.82) : ClipinInk.secondary
            )
        }
        .padding(.horizontal, emphasized ? 10 : 0)
        .padding(.vertical, emphasized ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                .fill(emphasized ? Color.accentColor.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.badgeCornerRadius, style: .continuous)
                        .strokeBorder(emphasized ? Color.accentColor : Color.clear, lineWidth: 0.5)
                )
        )
    }
```
改为(删 `emphasized` 参数与全部手绘块):
```swift
    private func keyBadge(label: String, key: String) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            ClipinKeycap(key: key, foreground: ClipinInk.secondary)
        }
    }
```

- [ ] **Step 5：构建,确认零警告**

Run 构建命令。期望:`** BUILD SUCCEEDED **`,无新增 warning。

- [ ] **Step 6：grep 门 + 结构断言**

```bash
grep -n "Circle()" Clipin/Views/MainPanel.swift | wc -l                          # 期望 0
grep -n "strokeBorder(Color.accentColor" Clipin/Views/MainPanel.swift | wc -l    # 期望 0
grep -n "GlassEffectContainer" Clipin/Views/MainPanel.swift | wc -l              # 期望 1(仅 bottomBar 这一个)
grep -n "emphasized" Clipin/Views/MainPanel.swift | wc -l                        # 期望 0(死参数删净)
```

- [ ] **Step 7：回归自检(实现者逐条对照,non-fabricated)**

对照源码确认未破坏:`bottomBar` 内 hover 展开命令簇逻辑、`isFooterHovered` onHover、各 Button action、`sourceBreadcrumb`/`commandCluster` 内容、`pasteSelected/pastePlainSelected/pasteRepresentationSelected/openSelected/previewSelected/toggleActionsPalette/toggleContinuousPaste` 调用、transition/animation 修饰符,均与改前**字节级一致**(只材质/容器/形状变)。

- [ ] **Step 8：commit**

```bash
git add Clipin/Views/MainPanel.swift
git commit -m "refactor: 单元3 底栏归一为单个原生 Liquid Glass 簇

【根因/背景】底栏原是5个独立块拼盘(真玻璃+手绘accent混排)致不原生。
按 Apple 'glass 不能采样 glass,须 GlassEffectContainer 归一':整簇包进
单个容器;删 Paste 手绘 Circle(强调交 .glassProminent 自身);
continuousPastePill 改 .glassEffect(.regular.tint)+系统tint;keyBadge
删 emphasized 死分支与手绘 accent 矩形。
【踩坑记录】hover/键盘/transition/各 action 必须字节不变,只改材质/容器/
形状。footer 全 Capsule 天然同心,无需 .containerConcentric。
【改动范围】MainPanel bottomBar 包 GlassEffectContainer;pasteCallToAction
去 Circle;continuousPastePill 原生玻璃;keyBadge 去死参数+手绘块。"
```

---

## 全部完成后

- [ ] **最终全量门**(控制者执行):重跑 spec「验证方式」全部 grep 门 + 构建零警告;逐条对照 spec「视觉逐项核查」#1-11 与「回归核查」做静态确认。
- [ ] **Codex 无偏见复审**(CLAUDE.md 强制):`codex:codex-rescue`,重点 spec 收尾清单(主面板 ClipinContentSurface 清净且 struct/辅助窗口保留、底栏无手绘 accent 残留、外壳玻璃删净无悬空背景、NSVisualEffectView 未误删、无障碍未被覆盖、横滚胶囊玻璃为已记录的用户优先例外不判违规)。复审发现按 receiving-code-review 批判性分诊,修完闭环。
- [ ] **用户真机视觉验收**:交用户真机构建截图验收(唯一材质验收口径,mock 不算)。**不达标不并 main(绝不带病合并)**。通过后才 superpowers:finishing-a-development-branch。
