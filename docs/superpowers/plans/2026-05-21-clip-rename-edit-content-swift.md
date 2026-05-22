# Clipin Rename + Edit Content — Swift 前端实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Clipin 主面板实现访达式 inline 改名(Rename)与 preview 区可编辑内容(Edit Content),入口为 ⌘K 动作面板。

**Architecture:** Rename 把列表行标题文字原地切换为 `TextField`;Edit Content 把右侧 preview 内容区切换为 `TextEditor`。两个编辑态由 `ClipboardViewModel` 的 `renamingItemID` / `editingContentItemID` 两个 `@Published` 状态驱动,`AppDelegate` 键盘监视器据此新增两个上下文,编辑期间把键盘交还给 SwiftUI 文本控件。

**Tech Stack:** SwiftUI, AppKit(NSEvent 键盘监视), UniFFI binding(`ClipinCore`)。

**关联 spec:** `docs/superpowers/specs/2026-05-21-clip-rename-edit-content-design.md`(单元 4-9)

## 前置条件

本计划依赖配套的 Rust 计划 `2026-05-21-clip-rename-edit-content-rust.md` **已全部完成**,且已执行 `./scripts/build-rust.sh` 重新生成 `Clipin/Generated/` 下的 UniFFI binding。生成后 Swift 端应具备:
- `ClipItem.alias: String?` / `ClipListItem.alias: String?`
- `ClipinCore.setAlias(id: String, alias: String?) throws`
- `ClipinCore.updateContent(id: String, newContent: String, newType: ClipType) throws`
- `ClipinCore.importItemIfMissing(...)` 签名新增 `alias: String?` 参数(位于 `createdAt` 与 `representations` 之间)

## 测试策略

Rust 层已由配套计划用 `cargo test --lib` 全覆盖。Swift 层以 SwiftUI 视图为主,无法单元测试;本计划的验证方式:
- **每个 task 结束跑构建**:`xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`,确认编译通过。
- **纯逻辑**(Task 3 的 `httpURLString`)给单元测试。
- **UI 行为**由 Task 9 的端到端手动验收 checklist 覆盖。

## 与 spec 的现实修正

- spec 单元 6 提到"Edit Content 改 url 后清空 favicon/og:title 缓存"。代码现实是 `FaviconCache` 按 URL/origin 作 key(见 `ClipItemRow.swift` 中 `RowFaviconView` 注释),`URLPreviewView` 也按 URL 抓 og:title——content 编辑成新 URL 后,渲染层用新 URL 作 key 自然走新缓存条目,旧缓存不会被错误命中。因此**无需手动失效缓存**,本计划不包含该步骤。

**所有 `xcodebuild` 命令在仓库根目录 `/Users/chenlei/work/person/Clipin` 执行。**

---

### Task 1: ArchiveService 接入 alias

**Files:**
- Modify: `Clipin/Services/ArchiveService.swift`(`ArchiveItem` 结构体 291-301;导出 `writeArchiveSnapshot` 215-236;导入 `importItemIfMissing` 调用 133-142)

Rust 计划改了 `importItemIfMissing` 签名,Swift 工程当前唯一的调用点(`ArchiveService`)会编译失败。本 task 修复并让别名进入导出/导入。

- [ ] **Step 1: `ArchiveItem` 增加 alias 字段**

`ArchiveItem` 结构体在 `representations` 字段之后追加(Optional 保证旧 archive 向后兼容解码):

```swift
    /// v2.1 起：用户别名。旧 archive 没有该字段，Optional 保证向后兼容解码。
    let alias: String?
```

- [ ] **Step 2: 导出时填充 alias**

`writeArchiveSnapshot` 内有两处 `ArchiveItem(...)` 构造(image 分支与非 image 分支)。两处都在 `representations: archiveReps` 之后加 `alias: item.alias`(`item` 是 `entry.item`,类型 `ClipItem`,已带 `alias`)。

image 分支改后:

```swift
                exportedItems.append(ArchiveItem(
                    content: item.content,
                    clipType: archiveType(for: item.clipType),
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    imageDataBase64: imageData.base64EncodedString(),
                    representations: archiveReps,
                    alias: item.alias
                ))
```

非 image 分支改后:

```swift
            exportedItems.append(ArchiveItem(
                content: item.content,
                clipType: archiveType(for: item.clipType),
                sourceApp: item.sourceApp,
                sourceName: item.sourceName,
                isPinned: item.isPinned,
                createdAt: item.createdAt,
                imageDataBase64: nil,
                representations: archiveReps,
                alias: item.alias
            ))
```

- [ ] **Step 3: 导入时传递 alias**

`importItemIfMissing` 调用(约 133-142)在 `createdAt:` 之后、`representations:` 之前插入 `alias:`:

```swift
                didImport = try core.importItemIfMissing(
                    content: item.content,
                    clipType: clipType,
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    imagePath: imagePath,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    alias: item.alias,
                    representations: coreReps
                )
```

- [ ] **Step 4: 构建确认通过**

Run: `xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add Clipin/Services/ArchiveService.swift
git commit -m "$(cat <<'EOF'
feat: 备份导入导出接入条目别名

【根因/背景】Rust 层已为 importItemIfMissing 增加 alias 参数，Swift 调用点需同步
【改动范围】ArchiveService 的 ArchiveItem 加 alias 字段、导出填充、导入传递
EOF
)"
```

---

### Task 2: PaletteActionShortcut 增加 Rename / Edit Content 快捷键

**Files:**
- Modify: `Clipin/App/LauncherKeyRouting.swift`(`KeyCode` enum 4-32;`PaletteActionShortcut` 34-65)

`Rename` 用面板内快捷键 `⇧⌘E`、`Edit Content` 用 `⌘E`。两者只在 ⌘K 动作面板打开时生效(由 `handlePaletteKeyEvent` → `executePaletteShortcut` 路由),不注册全局热键。

- [ ] **Step 1: `KeyCode` 增加字母 E**

`KeyCode` enum 内,在 `letterC` 一行之后追加(E 的 Carbon HID keyCode 是 `0x0E`):

```swift
    static let letterE: UInt16 = 0x0E
```

- [ ] **Step 2: `PaletteActionShortcut` 增加两个定义**

在 `pasteAsRTF` 静态定义之后追加:

```swift
    static let rename = Self(badge: "⇧⌘E", keyCode: KeyCode.letterE, modifiers: [.command, .shift])
    static let editContent = Self(badge: "⌘E", keyCode: KeyCode.letterE, modifiers: .command)
```

- [ ] **Step 3: 加入 `all` 数组**

`all` 数组末尾(`.pasteAsRTF` 之后)追加两项:

```swift
        .pasteAsRTF,
        .rename,
        .editContent,
    ]
```

- [ ] **Step 4: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 提交**

```bash
git add Clipin/App/LauncherKeyRouting.swift
git commit -m "$(cat <<'EOF'
feat: 新增 Rename(⇧⌘E)/Edit Content(⌘E) 面板快捷键

【改动范围】LauncherKeyRouting 的 KeyCode 加 letterE；PaletteActionShortcut 加 rename/editContent 并入 all
EOF
)"
```

---

### Task 3: ViewModel + ClipboardMonitor — Rename / Edit Content 状态与方法

**Files:**
- Modify: `Clipin/Services/ClipboardMonitor.swift`(`extractURL` 266-272)
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`(`@Published` 属性区 31-55;`// MARK: - Actions` 方法区)
- Create: `ClipinTests/ClipboardMonitorURLTests.swift`

Rename 与 Edit Content 的两个编辑态互斥(`beginRenaming` 调 `cancelEditContent`,反之亦然),因此放在同一个 task 内一次完成。

- [ ] **Step 1: `ClipboardMonitor` 提取可复用的 URL 判定**

现有 `extractURL(from:)` 是 pasteboard 版,无法直接用于"判断一段文本是否 http(s) URL"。把判据提取为 `static` 纯函数,`extractURL` 内部改为复用它。

`ClipboardMonitor` 内,把现有:

```swift
    private func extractURL(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string),
              let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme) else { return nil }
        return text
    }
```

替换为:

```swift
    /// 判断一段文本是否为 http/https URL。是则原样返回（保留大小写与参数），否则 nil。
    /// Edit Content 保存时复用此判据，确保与剪贴板监控的 URL 识别口径一致。
    static func httpURLString(in text: String) -> String? {
        guard let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme) else { return nil }
        return text
    }

    private func extractURL(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return Self.httpURLString(in: text)
    }
```

- [ ] **Step 2: ViewModel 新增 `@Published` 状态**

在 `@Published private(set) var selectedRepresentationUTIs: [String] = []`(第 55 行)之后追加:

```swift
    /// 非 nil 表示该 id 的列表行正处于 inline 改名编辑态。
    @Published var renamingItemID: String?
    /// inline 改名 TextField 的草稿文本。
    @Published var renameDraft: String = ""
    /// 非 nil 表示该 id 的条目正处于 preview 区内容编辑态。
    @Published var editingContentItemID: String?
    /// Edit Content TextEditor 的草稿文本。
    @Published var editingContentDraft: String = ""
```

- [ ] **Step 3: ViewModel 新增 Rename 方法**

在 `ClipboardViewModel` 的 `// MARK: - Actions` 区段内、`copySelected` 方法之后新增。`items.first(where:)` 与既有 `selectedListItem` 同源;`core` / `loadItems` / `showNotice` / `loadItem(id:)` 均为既有成员。

```swift
    // MARK: - Rename

    /// 进入 inline 改名编辑态。预填该行当前显示名 displayTitle
    /// （别名优先；无别名时是按类型推导的标题：text/url 取内容首行、image 取来源+尺寸、file 取文件标题）。
    func beginRenaming(id: String) {
        guard let listItem = items.first(where: { $0.id == id }) else { return }
        if isShowingActions { hideActionsPalette() }
        cancelEditContent()        // 两个编辑态互斥
        // 预填用 displayTitle 而非 preview：preview 对 image/file 是 OCR/路径原文，
        // 拿来当改名预填毫无意义；displayTitle 才是用户当前在列表里看到的那行字。
        renameDraft = listItem.displayTitle
        renamingItemID = id
    }

    /// 提交别名。空字符串清空别名；非空写入。提交后刷新列表。
    func commitRenaming() {
        guard let id = renamingItemID else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingItemID = nil
        renameDraft = ""
        do {
            try core.setAlias(id: id, alias: trimmed.isEmpty ? nil : trimmed)
            loadItems()
            showNotice(NSLocalizedString("Renamed.", comment: ""), style: .success)
        } catch {
            print("⚠️ setAlias failed (id=\(id)): \(error)")
            showNotice(NSLocalizedString("Could not rename this item.", comment: ""), style: .error)
        }
    }

    /// 放弃改名，不写库。
    func cancelRenaming() {
        renamingItemID = nil
        renameDraft = ""
    }
```

- [ ] **Step 4: ViewModel 新增 Edit Content 方法**

紧接 Step 3 的 Rename 方法之后新增:

```swift
    // MARK: - Edit Content

    /// 进入 preview 区内容编辑态。仅 text/url 类型可编辑。
    func beginEditContent(id: String) {
        guard let listItem = items.first(where: { $0.id == id }),
              listItem.clipType == .text || listItem.clipType == .url else { return }
        if isShowingActions { hideActionsPalette() }
        cancelRenaming()           // 两个编辑态互斥
        guard let full = loadItem(id: id) else { return }
        editingContentDraft = full.content
        editingContentItemID = id
    }

    /// 提交编辑后的内容。依据新内容重新判定类型，提交后刷新。
    func commitEditContent() {
        guard let id = editingContentItemID else { return }
        let newContent = editingContentDraft
        let probe = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let newType: ClipType = ClipboardMonitor.httpURLString(in: probe) != nil ? .url : .text
        editingContentItemID = nil
        editingContentDraft = ""
        do {
            try core.updateContent(id: id, newContent: newContent, newType: newType)
            loadItems()
            showNotice(NSLocalizedString("Content saved.", comment: ""), style: .success)
        } catch {
            print("⚠️ updateContent failed (id=\(id)): \(error)")
            showNotice(NSLocalizedString("Could not save content.", comment: ""), style: .error)
        }
    }

    /// 放弃内容编辑，不写库。
    func cancelEditContent() {
        editingContentItemID = nil
        editingContentDraft = ""
    }
```

- [ ] **Step 5: 为 `httpURLString` 写单元测试**

新建 `ClipinTests/ClipboardMonitorURLTests.swift`(参照该 target 内现有测试文件的 import 与命名风格):

```swift
import XCTest
@testable import Clipin

final class ClipboardMonitorURLTests: XCTestCase {
    func testHTTPSURLIsRecognized() {
        XCTAssertEqual(ClipboardMonitor.httpURLString(in: "https://anthropic.com"), "https://anthropic.com")
    }

    func testHTTPURLIsRecognized() {
        XCTAssertEqual(ClipboardMonitor.httpURLString(in: "http://192.168.1.1:8080/x"), "http://192.168.1.1:8080/x")
    }

    func testPlainTextIsNotURL() {
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "just some text"))
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "ftp://example.com"))
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "mailto:a@b.com"))
    }
}
```

- [ ] **Step 6: 构建并运行测试**

Run: `xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS' test`
Expected: BUILD SUCCEEDED;`ClipboardMonitorURLTests` 4 个用例通过。

> 若该 target 的测试无法在当前环境跑(签名/destination 限制),退而求其次只跑 `xcodebuild ... build`,并把 `httpURLString` 的验证并入 Task 9 手动验收。

- [ ] **Step 7: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/Services/ClipboardMonitor.swift ClipinTests/ClipboardMonitorURLTests.swift
git commit -m "$(cat <<'EOF'
feat: ViewModel 增加 Rename / Edit Content 状态与方法

【根因/背景】inline 改名与内容编辑由 renamingItemID / editingContentItemID 两个状态驱动
【踩坑记录】两个编辑态互斥；Edit Content 保存复用 ClipboardMonitor.httpURLString 判定新类型，与剪贴板监控口径一致
【改动范围】ClipboardViewModel 加状态与 begin/commit/cancel 方法；ClipboardMonitor 提取 httpURLString
EOF
)"
```

---

### Task 4: 动作面板增加 Rename / Edit Content 命令

**Files:**
- Modify: `Clipin/Views/ActionPalette.swift`(`ActionPaletteBuilder.actions` 212-283)

在依赖选中项的动作块内(`if let selected = viewModel.selectedListItem`),`Pin` 动作之后、`Open` 动作之前插入两个命令。`Rename` 对全部类型可用;`Edit Content` 仅 text/url。两者 `restoresSearchFocus: false`——执行后焦点要交给 inline 编辑控件,不抢回搜索框。

- [ ] **Step 1: 插入两个 PaletteAction**

在 `ActionPaletteBuilder.actions` 的 `Pin/Unpin` 那条 `list.append` 之后、`if viewModel.canOpenSelectedItem {` 之前插入:

```swift
            list.append(PaletteAction("Rename", systemImage: "pencil", shortcut: .rename, restoresSearchFocus: false) {
                viewModel.beginRenaming(id: selected.id)
            })

            if selected.clipType == .text || selected.clipType == .url {
                list.append(PaletteAction("Edit Content", systemImage: "square.and.pencil", shortcut: .editContent, restoresSearchFocus: false) {
                    viewModel.beginEditContent(id: selected.id)
                })
            }
```

- [ ] **Step 2: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 3: 提交**

```bash
git add Clipin/Views/ActionPalette.swift
git commit -m "$(cat <<'EOF'
feat: 动作面板增加 Rename / Edit Content 命令

【根因/背景】两个功能的唯一入口是 ⌘K 动作面板
【踩坑记录】Edit Content 仅对 text/url 出现；两者 restoresSearchFocus=false，执行后焦点交给 inline 编辑控件
【改动范围】ActionPaletteBuilder 在 Pin 与 Open 之间插入两个 PaletteAction
EOF
)"
```

---

### Task 5: displayTitle 别名优先 + ClipItemRow inline 改名 UI + 列表锁定

**Files:**
- Modify: `Clipin/Views/ClipListItem+Display.swift`(`displayTitle` 计算属性 7-29)
- Modify: `Clipin/Views/ClipItemRow.swift`(`ClipItemRow` 结构体 311-489)
- Modify: `Clipin/Views/MainPanel.swift`(`ItemListView` 结构体约 421 起、`row(for:)` 手势约 541-542、`ItemListView` 实例化处约第 195 行)

`ClipItemRow` 当前是纯参数视图。改名需要它与 `ClipboardViewModel` 双向通信(读 `renamingItemID`、绑定 `renameDraft`、调 `commitRenaming`),给它注入 `@EnvironmentObject`。`MainPanel` 已对 `PreviewPane` 注入 `environmentObject(viewModel)`,本 task 给 `ItemListView` 也注入,使其自身与子树内的 `ClipItemRow` 都能取到。

本 task 同时落实两条**编辑态退出/锁定规则**(spec 单元 5/6):
- Rename:`TextField` 失焦即自动提交(访达式)——覆盖"改名进行中点击其他行"。
- Edit Content:编辑进行中**锁定**列表选中切换——鼠标点击其他行不切换。

- [ ] **Step 1: `ClipListItem+Display.swift` — `displayTitle` 别名优先**

`displayTitle` 是列表行标题与 ⌘K 动作面板头部共用的显示名推导(`ClipItemRow.displayText`、`ActionPalette` 头部都读它)。"别名优先于一切类型标题"必须在这里做,**不能**在 Rust 的 SQL `preview` 列做——理由见 Rust 计划 Task 5:`preview` 还被 favicon / hex 颜色检测复用,且 image/file 的标题由 `displayTitle` 从元信息推导、根本不读 `preview`。在这里加一处判断,四类条目(text/url/image/file)统一获得别名优先。

`displayTitle` 的 `switch clipType` **之前**插入别名短路:

```swift
    var displayTitle: String {
        // 别名优先于一切类型标题：用户显式命名的意图最高，覆盖 text/url/image/file 四类。
        if let alias, !alias.isEmpty { return alias }
        switch clipType {
        // ...现有 text/url/image/file 分支保持不变...
        }
    }
```

- [ ] **Step 2: `MainPanel` 给 `ItemListView` 注入 environmentObject**

`MainPanel.swift` 约第 192 行的 `ItemListView(...)` 调用,在其闭合括号之后链式追加 `.environmentObject(viewModel)`。即把:

```swift
            ItemListView(
                ... 现有参数 ...
            )
```

改为:

```swift
            ItemListView(
                ... 现有参数 ...
            )
            .environmentObject(viewModel)
```

(若 `ItemListView(...)` 之后已有其他链式 modifier,把 `.environmentObject(viewModel)` 加在它们之前即可。)

- [ ] **Step 3: `ItemListView` 增加 vm 引用,Edit Content 期间锁定列表交互**

`ItemListView` 结构体属性区(`@State private var hoveredID: String?` 之后)追加:

```swift
    @EnvironmentObject private var vm: ClipboardViewModel
```

`row(for:)` 末尾的两个点击手势(当前为):

```swift
        .onTapGesture(count: 2) { onActivate(item) }
        .simultaneousGesture(TapGesture(count: 1).onEnded { selection.wrappedValue = item.id })
```

改为 Edit Content 进行中锁定(改的是真实内容,误点切走有丢编辑/误存风险,必须显式 Save/Esc 结束):

```swift
        .onTapGesture(count: 2) {
            if vm.editingContentItemID == nil { onActivate(item) }
        }
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            if vm.editingContentItemID == nil { selection.wrappedValue = item.id }
        })
```

> 注:Rename 进行中**不**锁定列表点击 —— 点击其他行靠 Step 5 的"失焦自动提交"处理(访达式),与 Edit Content 的锁定是有意的不对称。

- [ ] **Step 4: `ClipItemRow` 增加 environmentObject 与编辑态计算属性**

`ClipItemRow` 结构体属性区(`let sceneState: ClipinSceneState` 之后)追加:

```swift
    @EnvironmentObject private var vm: ClipboardViewModel
    @FocusState private var aliasFieldFocused: Bool

    private var isRenaming: Bool { vm.renamingItemID == item.id }
    private var hasAlias: Bool { item.alias?.isEmpty == false }
```

- [ ] **Step 5: body 标题区改为条件渲染 + 失焦自动提交**

`body` 的 `HStack` 内,当前的 `Text(highlightedDisplayText)` 整块(约第 327-335 行,含其全部 modifier 与注释)替换为:

```swift
            if isRenaming {
                TextField("", text: $vm.renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .regular))
                    .focused($aliasFieldFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onSubmit { vm.commitRenaming() }
                    .onChange(of: aliasFieldFocused) { _, focused in
                        // 访达式：TextField 失焦（点击其他行 / 面板外部 / 面板关闭）即自动提交。
                        // commitRenaming 幂等——renamingItemID 为 nil 时直接 return，
                        // 故 Return(onSubmit) 与 Esc(cancelRenaming) 先行清空后，此处不会重复写库。
                        if !focused { vm.commitRenaming() }
                    }
                    .onAppear {
                        aliasFieldFocused = true
                        // SwiftUI TextField 无直接全选 API：获焦后异步选中 field editor 文本，
                        // 让用户可一键整体替换（访达改名肌肉记忆）。
                        DispatchQueue.main.async {
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                        }
                    }
            } else {
                // 非编辑态：保持 ClipItemRow 现有只读标题样式 —— 字重恒为 .regular，
                // 选中走 accent 色、未选纯 Color.primary。务必照搬当前代码，
                // 不要写成 v9 的 weight: isSelected ? .semibold 或 .opacity(0.82)。
                Text(highlightedDisplayText)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
```

- [ ] **Step 6: 增加"有别名"视觉信号**

`body` 的 `HStack` 内,`typeIndicator` 那一整块(`typeIndicator.scaleEffect(...).animation(...)`)之后、标题区之前,插入一个固定宽度的别名标记位(有别名画 accent 小圆点,无别名占等宽空位,保证两种行左对齐一致):

```swift
            ZStack {
                if hasAlias && !isRenaming {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 6)
```

- [ ] **Step 7: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 8: 手动验收**

构建并运行 app:
- ⌘⇧V 唤起面板,选中一条文本条目,⌘K → 选 `Rename`:该行标题原地变为 `TextField`,文字预填且全选,光标在该行。
- 输入新名 → Return:该行立即显示新别名,行首出现 accent 小圆点,底部 notice "Renamed."。
- 再次 Rename,清空文字 → Return:该行回退为内容兜底预览,小圆点消失。
- 进入 Rename,**鼠标点击列表另一行**:当前别名自动提交(失焦),选中切到新行——无孤儿编辑态残留。

- [ ] **Step 9: 提交**

```bash
git add Clipin/Views/ClipListItem+Display.swift Clipin/Views/ClipItemRow.swift Clipin/Views/MainPanel.swift
git commit -m "$(cat <<'EOF'
feat: displayTitle 别名优先 + 列表行 inline 改名 UI + 编辑态列表锁定

【根因/背景】访达式改名——列表行标题原地切换为 TextField；别名优先显示统一在 displayTitle
【踩坑记录】别名优先必须在 displayTitle 做、不在 SQL preview——image/file 列表标题由 displayTitle 从元信息推导、不读 preview，且 preview 还被 favicon 复用；ClipItemRow 原为纯参数视图，改名需与 vm 双向通信，故经 ItemListView 注入 environmentObject；TextField 无全选 API，获焦后异步 selectAll field editor；改名失焦即提交（访达式），Edit Content 期间锁定列表点击（重动作需显式确认）
【改动范围】ClipListItem+Display.swift displayTitle 加别名优先；ClipItemRow 加 environmentObject/FocusState/编辑态条件渲染/失焦提交/别名视觉信号；ItemListView 加 vm 并锁定 row 手势；MainPanel 给 ItemListView 注入 environmentObject
EOF
)"
```

---

### Task 6: PreviewPane Edit Content 编辑态 UI

**Files:**
- Modify: `Clipin/Views/PreviewPane.swift`(`body` 20-50;新增 `contentEditor`)

进入 Edit Content 时,preview 内容区整体切换为 `TextEditor` + Save/Cancel。`PreviewPane` 已有 `@EnvironmentObject var vm`。

- [ ] **Step 1: 增加 FocusState**

`PreviewPane` 结构体属性区(`@State private var metadataRevision: Int = 0` 之后)追加:

```swift
    @FocusState private var contentEditorFocused: Bool
```

- [ ] **Step 2: body 增加编辑态分支**

`body` 的 `Group` 内,当前:

```swift
            if let item {
                contentStage(for: item)
            } else if vm.selectedListItem != nil {
```

改为:

```swift
            if let item {
                if vm.editingContentItemID == item.id {
                    contentEditor(for: item)
                } else {
                    contentStage(for: item)
                }
            } else if vm.selectedListItem != nil {
```

- [ ] **Step 3: 新增 `contentEditor` 方法**

在 `PreviewPane` 内 `contentStage(for:)` 方法之后新增。复用既有 `contentStage<Content:>` 容器。`ClipinKeycap(key:foreground:)` 与 `ClipinInk.secondary` 是既有组件/token(`ActionPalette.swift` 在用)。

```swift
    private func contentEditor(for item: ClipItem) -> some View {
        contentStage {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $vm.editingContentDraft)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($contentEditorFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                HStack(spacing: 10) {
                    Spacer()
                    Button(LocalizedStringKey("Cancel")) {
                        vm.cancelEditContent()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ClipinInk.secondary)

                    Button {
                        vm.commitEditContent()
                    } label: {
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey("Save"))
                            ClipinKeycap(key: "⌘↵", foreground: ClipinInk.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .onAppear { contentEditorFocused = true }
        }
    }
```

- [ ] **Step 4: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 5: 手动验收**

- 选中一条文本条目,⌘K → 选 `Edit Content`:右侧 preview 变为带边框的 `TextEditor`,预填完整内容,光标在编辑器内,底部出现 Cancel / Save(⌘↵)。
- 改几个字 → 点 Save:preview 回到只读态,显示新内容,notice "Content saved."。
- 选中一条 URL 条目,Edit Content,把内容改成非 URL 文本并保存:该条目类型应变为 text(列表行图标从 favicon 变为文本图标)。
- 选中图片条目,⌘K:命令列表里**不应**出现 `Edit Content`(只有 `Rename`)。

- [ ] **Step 6: 提交**

```bash
git add Clipin/Views/PreviewPane.swift
git commit -m "$(cat <<'EOF'
feat: PreviewPane 内容编辑态 UI

【根因/背景】Edit Content 把右侧 preview 内容区切换为可编辑 TextEditor
【改动范围】PreviewPane body 增加 editingContentItemID 分支；新增 contentEditor（TextEditor + Save/Cancel）
EOF
)"
```

---

### Task 7: AppDelegate 键盘上下文路由

**Files:**
- Modify: `Clipin/App/AppDelegate.swift`(`KeyboardContext` enum 182-188;`keyboardContext` 1018-1029;主 keyMonitor switch 850-861;新增两个 handler)

inline 改名 / 内容编辑进行中,键盘焦点在 SwiftUI 文本控件上。需新增两个键盘上下文,把绝大多数按键交还给文本控件(含 IME),只在该层处理 Esc(取消)与 ⌘↵(Edit Content 提交)。

- [ ] **Step 1: `KeyboardContext` 增加两个 case**

`KeyboardContext` enum(182-188)在 `case actionsPalette(ClipboardViewModel)` 之后追加:

```swift
        case renamingItem(ClipboardViewModel)
        case editingContent(ClipboardViewModel)
```

- [ ] **Step 2: `keyboardContext` 优先判断编辑态**

`keyboardContext` computed 的 panel 分支(当前):

```swift
        if let panel, panel.isVisible, panel.isKeyWindow, let viewModel {
            return viewModel.isShowingActions ? .actionsPalette(viewModel) : .mainPanel(viewModel)
        }
```

改为:

```swift
        if let panel, panel.isVisible, panel.isKeyWindow, let viewModel {
            if viewModel.renamingItemID != nil { return .renamingItem(viewModel) }
            if viewModel.editingContentItemID != nil { return .editingContent(viewModel) }
            return viewModel.isShowingActions ? .actionsPalette(viewModel) : .mainPanel(viewModel)
        }
```

- [ ] **Step 3: 主 keyMonitor switch 增加两个分支**

`startKeyMonitor` 内的 `switch self.keyboardContext`(850-861),在 `case .actionsPalette(let vm):` 分支之后追加:

```swift
            case .renamingItem(let vm):
                return self.handleRenamingKeyEvent(event, viewModel: vm)
            case .editingContent(let vm):
                return self.handleEditingContentKeyEvent(event, flags: flags, viewModel: vm)
```

- [ ] **Step 4: 新增两个 handler**

在 `handlePaletteKeyEvent` 方法之后新增。改名态:除 Esc 外全部 `return event` 交给 inline `TextField`(Return → `TextField.onSubmit` → `commitRenaming`;字符 / IME 组词 / 方向键均由 TextField 自行处理)。编辑态:拦截 ⌘↵ 提交、Esc 取消,其余 `return event` 交给 `TextEditor`(普通 Return 换行、IME 选字)。

```swift
    private func handleRenamingKeyEvent(_ event: NSEvent, viewModel vm: ClipboardViewModel) -> NSEvent? {
        if event.keyCode == KeyCode.escape {
            vm.cancelRenaming()
            return nil
        }
        // 其余按键（含 Return / ↑↓ / Tab / Space / ⌘1-9 / IME 组词）全部交还给 inline TextField。
        return event
    }

    private func handleEditingContentKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.returnKey where flags == .command:
            vm.commitEditContent()
            return nil
        case KeyCode.escape:
            vm.cancelEditContent()
            return nil
        default:
            // 其余按键（含普通 Return 换行、IME 组词、方向键）交还给 TextEditor。
            return event
        }
    }
```

- [ ] **Step 5: `hidePanel` 关闭面板时清理编辑态**

面板关闭(点击面板外部、⌘⇧V 等非 Esc 路径)时,改名/编辑态不会被清,会污染下次打开。参照 CLAUDE.md「`hidePanel` 时强制 `isContinuousPasteEnabled = false`」的既有先例,在 `hidePanel(restorePreviousApp:)` 函数内、`viewModel?.isContinuousPasteEnabled = false`(约第 660 行)之后追加两行:

```swift
        viewModel?.commitRenaming()      // 改名进行中关面板 = 提交（与失焦自动提交一致）
        viewModel?.cancelEditContent()   // 内容编辑进行中关面板 = 放弃，不静默写入
```

(两个方法都幂等:无对应编辑态时 `guard` 直接 return。)

- [ ] **Step 6: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 7: 手动验收**

- 进入 inline 改名,按 ↑↓:列表选中项**不移动**(键给了 TextField);输入中文(拼音):IME 选字面板正常,空格选字、回车确认字符都正常;改完按 Return:提交别名。
- 进入改名,按 Esc:取消改名,该行恢复原显示。
- 进入 Edit Content,按 ↑↓ / 普通 Return:在 TextEditor 内移动光标 / 换行,列表不动;按 ⌘↵:保存;按 Esc:取消。
- 进入改名 / Edit Content,点击面板外部关闭面板,再 ⌘⇧V 重新打开:**无残留编辑态**(列表正常、preview 只读)。

- [ ] **Step 8: 提交**

```bash
git add Clipin/App/AppDelegate.swift
git commit -m "$(cat <<'EOF'
feat: 键盘上下文路由支持改名/编辑态

【根因/背景】inline 改名与内容编辑期间，键盘须交还给 SwiftUI 文本控件，不能被列表导航截走
【踩坑记录】renamingItem/editingContent 上下文优先于 mainPanel 判定；改名态除 Esc 外全放行（含 IME），编辑态额外拦 ⌘↵ 提交；hidePanel 须清理编辑态防残留污染，照 isContinuousPasteEnabled 先例
【改动范围】AppDelegate 的 KeyboardContext 加两 case、keyboardContext 优先判断、主 switch 加分支、新增两个 handler、hidePanel 加编辑态清理
EOF
)"
```

---

### Task 8: 本地化文案

**Files:**
- Modify: `Clipin/Resources/en.lproj/Localizable.strings`
- Modify: `Clipin/Resources/zh-Hans.lproj/Localizable.strings`

新增 key 来自:动作面板命令标题(`Rename` / `Edit Content`)、编辑器按钮(`Save` / `Cancel`)、操作回声 notice。`Save` / `Cancel` 若文件中已存在则不重复添加。

- [ ] **Step 1: 英文文案**

`Clipin/Resources/en.lproj/Localizable.strings` 末尾追加(已存在的 key 跳过):

```
"Rename" = "Rename";
"Edit Content" = "Edit Content";
"Save" = "Save";
"Cancel" = "Cancel";
"Renamed." = "Renamed.";
"Could not rename this item." = "Could not rename this item.";
"Content saved." = "Content saved.";
"Could not save content." = "Could not save content.";
```

- [ ] **Step 2: 简体中文文案**

`Clipin/Resources/zh-Hans.lproj/Localizable.strings` 末尾追加(已存在的 key 跳过):

```
"Rename" = "重命名";
"Edit Content" = "编辑内容";
"Save" = "保存";
"Cancel" = "取消";
"Renamed." = "已重命名。";
"Could not rename this item." = "无法重命名该条目。";
"Content saved." = "内容已保存。";
"Could not save content." = "无法保存内容。";
```

- [ ] **Step 3: 构建确认通过**

Run: `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 手动验收**

把系统语言切到简体中文(或在 scheme 里设 app language 为简体中文)运行:动作面板里显示"重命名 / 编辑内容",编辑器按钮显示"保存 / 取消",改名/编辑成功 notice 为中文。

- [ ] **Step 5: 提交**

```bash
git add Clipin/Resources/en.lproj/Localizable.strings Clipin/Resources/zh-Hans.lproj/Localizable.strings
git commit -m "$(cat <<'EOF'
feat: Rename / Edit Content 文案本地化

【改动范围】en.lproj / zh-Hans.lproj 新增动作标题、编辑器按钮、操作 notice 文案
EOF
)"
```

---

### Task 9: 端到端手动验收

**Files:** 无(纯验收)

- [ ] **Step 1: 完整构建并运行**

Run: `./scripts/build-rust.sh && xcodegen generate && xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -destination 'generic/platform=macOS' build`
Expected: BUILD SUCCEEDED。运行编译出的 app。

- [ ] **Step 2: Rename 验收**

- [ ] text / url / image / file 四种类型条目都能 ⌘K → Rename;改名后列表行只显示别名,行首有 accent 小圆点。
- [ ] 改名 inline 编辑:预填当前显示名且全选;Return 提交;Esc 取消恢复原状。
- [ ] 提交空字符串 = 删除别名,列表回退为 displayTitle 按类型推导的标题,小圆点消失。
- [ ] 改名后用别名搜索能命中(英文别名直接搜、中文别名拼音搜)。
- [ ] pinned 视图与普通视图都能改名,别名一致。
- [ ] 改名进行中按 ↑↓ 列表不移动;中文输入法组词正常。
- [ ] 改名进行中鼠标点击列表其他行 → 别名自动提交、选中切到新行(访达式),无孤儿编辑态。

- [ ] **Step 3: Edit Content 验收**

- [ ] text / url 条目 ⌘K 有 `Edit Content`;image / file 条目**没有**该命令。
- [ ] Edit Content:preview 变 TextEditor 预填完整内容;⌘↵ 保存、Esc 取消。
- [ ] 保存后该条目后续粘贴出去是新内容。
- [ ] 把 text 编辑成 `https://…` 并保存:类型变 url(列表图标变 favicon);反之亦然。
- [ ] 编辑期间 ↑↓ / 普通 Return 在编辑器内生效,列表不动。
- [ ] 编辑内容进行中鼠标点击列表其他行 → 选中**不切换**(锁定),须 Save/Esc 结束编辑。

- [ ] **Step 4: 备份验收**

- [ ] 给若干条目改名 → 导出备份 → 清空历史 → 导入备份:别名随条目恢复。

- [ ] **Step 5: 回归检查**

- [ ] 不进入任何编辑态时,主面板 ↑↓ / Return / ⌘K / ⌘1-9 / Tab / Space / Esc 行为与改动前一致。
- [ ] ⌘K 动作面板的其余命令(Paste / Copy / Pin / Open / Delete 等)不受影响。
- [ ] 改名 / Edit Content 进行中点击面板外部关闭面板,再 ⌘⇧V 重新打开 → 无残留编辑态。
