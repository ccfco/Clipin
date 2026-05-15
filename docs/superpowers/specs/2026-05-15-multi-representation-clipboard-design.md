# 多 Representation 剪贴板：格式无损往返设计

> **状态**：设计已确认，待 implementation plan
> **日期**：2026-05-15
> **目标版本**：v0.X.0
> **关联用户诉求**：对标 Raycast 2.0 "saves every original format you copied and lets you restore them"，做到比 Raycast 更有用户感知

---

## 1. 背景与目标

### 1.1 现状

Clipin 当前采集剪贴板时（`Clipin/Services/ClipboardMonitor.swift:92-108`）走 `file → url → image → text` 的 if/else 选**一种**最高语义 representation 写入 DB，其余 UTI（HTML/RTF、富文本附带的 plain text、浏览器复制的 URL+plain 组合）全部丢弃。粘贴时（`Clipin/Services/PasteService.swift:7-35`）也只写一种 UTI 回 NSPasteboard。

结果：从 Notion 复制富文本粘到 Slack，**富文本格式丢失**，链接被降级为纯文本。用户对 Clipin 的体感是"只能粘 plain"。

### 1.2 目标

- **格式无损往返**：从富文本应用复制，粘到富文本应用保留格式；粘到纯文本应用自动 plain
- **用户可感知**：preview/footer/动作面板都明确告诉用户"这条有多种格式"
- **互通规范**：用一份公开 JSON archive 格式让其他剪贴板工具理论上都能读写

### 1.3 非目标

- ❌ 直接和 Raycast 备份互通（Raycast 备份格式不公开、不承诺稳定）
- ❌ image / file 类型加多 representation（暂留 schema 口子）
- ❌ 智能按目标 app 分流粘贴（终端类强制 plain 等）——靠目标 app 自身处理 NSPasteboardItem 多 UTI 即可
- ❌ 向后兼容（v1 Clipin 读 v2 archive）——单人项目，只保留前向兼容

---

## 2. 架构与数据流

### 2.1 核心抽象

一条剪贴板条目 = `(content, [representations])`：

- `content`：列表展示、搜索、显示用的"代表性 plain text"——FTS5 / OCR / pinyin 仍然只跟它走
- `representations`：额外的非冗余原生 UTI BLOB，**只在粘贴和导出时使用**

### 2.2 数据流

```
[复制]
  NSPasteboard 多 UTI
    ↓ ClipboardMonitor.extractRepresentations (UTI 白名单 + 去重 + 大小限制)
  Rust saveItem(content, [representations])
    ↓
  clip_items (主表 plain text) + clip_representations (副表 UTI BLOB)

[列表 / 搜索]
  仅查 clip_items；representations 不参与 FTS / 排序

[粘贴]
  Return         → loadRepresentations → NSPasteboardItem 整组写回（目标 app 自己挑）
  ⇧Return        → content 单一 plain text 写回（现状不变）
  ⌥H / ⌥R       → 单 UTI 写回（动作面板覆盖入口）

[备份]
  ArchiveService v2 → JSON 含 representations 数组 (base64)
  导入按 hash 去重；现有 representations 空时合并补齐
```

### 2.3 关键不变量

1. `content` 始终是 plain text；搜索 / 列表 / OCR / pinyin 逻辑零改动
2. HTML / RTF **不进 FTS5**——避免 markup 污染搜索
3. text 和 url 类型才存 representations；image / file 维持现状
4. 主条目删除时副表 ON DELETE CASCADE

---

## 3. 已锁定的决策

| 维度 | 决策 |
|---|---|
| **价值定位** | 格式无损往返（让目标 app 挑 UTI） |
| **UTI 范围** | 明确白名单：`public.utf8-plain-text` / `public.html` / `public.rtf` / `public.rtfd` / `public.url` / `public.file-url` / `public.png` / `public.tiff` / `public.jpeg` |
| **适用类型** | text 和 url 启用；image / file 暂留 schema 口子 |
| **粘贴粒度** | Return 全量 / ⇧Return plain / 动作面板 Paste as HTML/RTF/Plain |
| **默认 Return** | **路线 X：全量回放**（macOS 系统粘贴语义，目标 app 自己挑） |
| **HTML/RTF 进 FTS5** | 否 |
| **存储** | 副表 `clip_representations(item_id, uti, data BLOB)` + ON DELETE CASCADE |
| **互通** | Archive v2 公开 JSON 格式 |
| **规范文档位置** | 独立 GitHub repo（如 `Clipin-archive-format`），不绑定主仓库实现 |
| **向后兼容** | v2 Clipin 读 v1 archive（前向兼容）；v1 Clipin 读 v2 archive 不兼容（不做兜底） |
| **快捷键** | Paste as HTML = `⌥H`；Paste as RTF = `⌥R`；Paste as Plain = `⇧↵`（复用现有） |

---

## 4. 前端用户可感知点

### 4.1 Preview pane metadata（静态常驻）

在 preview 右侧 metadata block 加一行：

```
Formats   plain · html · rtf
```

每次选中条目都看到。单格式条目只显示 `plain`。

### 4.2 Footer command strip（主路径感知）

选中条目存在多 representation 时，footer 现有 "Plain Text" pill 旁多出 "HTML" / "RTF" pill。**条件显示**，没有就不占位。鼠标可点 + 键盘可达。

### 4.3 动作面板 ⌘K 动态命令

条目存在 HTML/RTF representation 时整组出现：

- `Paste as HTML` (⌥H)
- `Paste as RTF` (⌥R)
- `Paste as Plain Text` (⇧↵，复用现有 shortcut)

纯 plain 条目（老条目 / 终端 cat 等）**不显示**这组命令。

### 4.4 首次粘贴教育性 notice

用户第一次成功粘贴富文本到目标 app 时，主面板 footer 显示一次性 toast：

```
Pasted with 3 formats — HTML preserved
```

通过 `SettingsStore.richPasteNoticeCountSeen` 限制触发 1–3 次，之后静默。

### 4.5 不做：列表行的小标记

避免列表 chrome 视觉过载。CLAUDE.md "footer 是固定高度的 command strip / row 视觉节制" 原则。

---

## 5. Schema：Migration v9

### 5.1 副表设计

```sql
CREATE TABLE clip_representations (
    item_id  TEXT NOT NULL,
    uti      TEXT NOT NULL,
    data     BLOB NOT NULL,
    PRIMARY KEY (item_id, uti),
    FOREIGN KEY (item_id) REFERENCES clip_items(id) ON DELETE CASCADE
);

CREATE INDEX idx_representations_item_id ON clip_representations(item_id);

PRAGMA foreign_keys = ON;   -- SQLite 默认关，必须显式开
```

### 5.2 Migration 设计原则

- 老条目（v8 升 v9）**不回填** representations——它们就是 plain，副表空行
- 不引入"反向构造 HTML from plain" 的伪造逻辑
- v9 migration 只做 schema 升级，不做数据回填，秒级完成

### 5.3 启用 foreign_keys 的注意事项

**SQLite 默认 `foreign_keys = OFF`，且 PRAGMA 是 connection-scoped（每次打开连接必须重新设）**。当前 `storage.rs` 没有任何 `foreign_keys` 相关代码，意味着 ON DELETE CASCADE **不会生效**。

实施要求：
- `Storage::new` 在打开 connection 后**立即**执行 `PRAGMA foreign_keys = ON;`
- 所有走 connection pool / 重新打开 connection 的路径都要保证这个 PRAGMA 生效
- v9 migration 单元测试必须验证 `delete_item` 真的会 CASCADE 副表行

### 5.4 FTS5 触发器

副表与 FTS5 完全无关——不更新 `clip_items_au` 触发器，副表写入不导致 FTS5 写放大。

---

## 6. 采集路径（Phase 2）

### 6.1 入口改造

`ClipboardMonitor.checkClipboard` 在 text / url 分支末尾加：

```swift
let representations = extractRepresentations(from: pasteboard, primaryContent: text)
persist(.text(text, sourceApp, sourceName, representations))
```

### 6.2 UTI 白名单提取

```swift
private static let representationWhitelist: Set<NSPasteboard.PasteboardType> = [
    .html,                         // public.html
    .rtf,                          // public.rtf
    .init("public.rtfd"),
    .URL,                          // public.url（去重后保留）
]

private func extractRepresentations(
    from pasteboard: NSPasteboard,
    primaryContent: String
) -> [Representation] {
    var result: [Representation] = []
    var totalBytes = 0
    
    for type in pasteboard.types ?? [] {
        guard Self.representationWhitelist.contains(type) else { continue }
        guard let data = pasteboard.data(forType: type) else { continue }
        
        // 去重：data 等同于 primaryContent UTF8 → 跳过
        if let asString = String(data: data, encoding: .utf8),
           asString == primaryContent {
            continue
        }
        
        // 单 representation 上限 1MB
        guard data.count <= 1 * 1024 * 1024 else { continue }
        
        result.append(Representation(uti: type.rawValue, data: data))
        totalBytes += data.count
    }
    
    // 总和上限 4MB → fallback：仅保留 plain，丢弃所有 representations
    guard totalBytes <= 4 * 1024 * 1024 else { return [] }
    
    return result
}
```

### 6.3 隐私 / 敏感内容

- ConcealedType / TransientType 仍由 `shouldPersistContents` 在采集入口拦截（既有逻辑），不进入 representation 提取
- 自己写回的内容仍由 `monitor.pause()` 周期拦截

---

## 7. 粘贴路径（Phase 3）

### 7.1 三档分发

| 入口 | 调用 |
|---|---|
| Return（text/url） | `writeAllRepresentations(item)` |
| Return（image/file） | `writeToClipboard(item)`（现状不变） |
| ⇧Return | `writeAsPlainText(item)`（现状不变） |
| ⌘1-9 | 跟 Return 同路径 |
| 动作面板 Paste as HTML | `writeRepresentation(item, uti: "public.html")` |
| 动作面板 Paste as RTF | `writeRepresentation(item, uti: "public.rtf")` |
| 动作面板 Paste as Plain | `writeAsPlainText(item)`（同 ⇧Return） |

### 7.2 writeAllRepresentations

```swift
@discardableResult
static func writeAllRepresentations(_ item: ClipItem) -> Bool {
    guard item.clipType == .text || item.clipType == .url else {
        return writeToClipboard(item)
    }
    
    let pbItem = NSPasteboardItem()
    
    // 1) plain text 始终存在（从 content 重建）
    guard pbItem.setString(item.content, forType: .string) else { return false }
    
    // 2) url 类型额外 set public.url
    if item.clipType == .url {
        _ = pbItem.setString(item.content, forType: .URL)
    }
    
    // 3) 全部额外 representation
    for rep in item.representations {
        _ = pbItem.setData(rep.data, forType: .init(rep.uti))
    }
    
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects([pbItem])
}
```

### 7.3 writeRepresentation

```swift
@discardableResult
static func writeRepresentation(_ item: ClipItem, uti: String) -> Bool {
    let data: Data
    if uti == NSPasteboard.PasteboardType.string.rawValue {
        guard let bytes = item.content.data(using: .utf8) else { return false }
        data = bytes
    } else {
        guard let rep = item.representations.first(where: { $0.uti == uti }) else {
            return false   // 不 clearContents，保留用户系统剪贴板
        }
        data = rep.data
    }
    
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.setData(data, forType: .init(uti))
}
```

### 7.4 monitor pause / resume

`AppDelegate` 现有的 `executePasteFlow` 路径已经在所有粘贴入口外层包裹 `monitor.pause()` / `monitor.resume()`（见 `AppDelegate.swift:1285-1371`）。新的 `writeAllRepresentations` / `writeRepresentation` 复用同一调用栈，**自动继承 pause/resume，无需在 PasteService 内部重复**——避免 pause/resume 在两层都加形成嵌套调用 bug。

动作面板 Paste as X 触发时同样走 `executePasteFlow`，pause/resume 自然覆盖。

### 7.5 touchItem 统一

`writeAllRepresentations` 和 `writeRepresentation` 都属于"真实使用"，必须调用 `touchItem`（增加 paste_count）。⇧Return 现状已 touch，新增入口同样遵守。

### 7.6 终端类 app

**不做"强制 plain"**——现代终端（Warp、Ghostty、iTerm2、Terminal.app）拿到 NSPasteboardItem 多 UTI 时会自动取 plain；老式终端会自动 strip 富文本。强制 plain 反而堵死"在 Warp 里想保留颜色"的边缘需求。如果未来发现真有终端不兼容，再加 isTerminalApp → plain fallback。

---

## 8. 动作面板（Phase 4）

### 8.1 新增快捷键

`Clipin/App/LauncherKeyRouting.swift` 扩展：

```swift
static let pasteAsHTML = Self(badge: "⌥H", keyCode: KeyCode.letterH, modifiers: .option)
static let pasteAsRTF  = Self(badge: "⌥R", keyCode: KeyCode.letterR, modifiers: .option)
// pasteAsPlain 复用现有 .pastePlain（⇧↵）
```

### 8.2 动态生成逻辑

`ClipboardViewModel.representationActions(for item:)` 当且仅当条目存在 `public.html` 或 `public.rtf` 时整组出现：

```
1. Paste as HTML (⌥H)      ← 仅当 utis 含 public.html
2. Paste as RTF  (⌥R)      ← 仅当 utis 含 public.rtf
3. Paste as Plain Text (⇧↵) ← 整组出现时永远存在
```

顺序：富 → 纯。`section = .primary`。

### 8.3 Footer pill

`MainPanel` footer 在选中条目富 representation 存在时多出 `HTML` / `RTF` pill。点击效果等同于动作面板项。`lineLimit(1) + fixedSize(horizontal: true)`，遵循 CLAUDE.md "footer 是固定高度 command strip" 约束。

---

## 9. Archive v2（Phase 5）

### 9.1 JSON Schema

```json
{
  "schemaVersion": 2,
  "format": "clipin.clipboard-archive",
  "formatURL": "https://github.com/ccfco/Clipin-archive-format",
  "exportedAt": "2026-05-15T10:00:00Z",
  "items": [
    {
      "content": "Hello world",
      "clipType": "text",
      "sourceApp": "notion.id",
      "sourceName": "Notion",
      "isPinned": false,
      "createdAt": 1715000000,
      "imageDataBase64": null,
      "representations": [
        { "uti": "public.html", "dataBase64": "..." },
        { "uti": "public.rtf",  "dataBase64": "..." }
      ]
    }
  ]
}
```

### 9.2 兼容性

| Archive 版本 | v2 Clipin 行为 |
|---|---|
| v1（无 representations）| 正常导入，representations 默认空 |
| v2 → v2 | 完整导入 |

v1 Clipin 读 v2：**不兼容，不做兜底**（单人项目）。

### 9.3 导入去重合并

`import_item_if_missing` Rust 入参扩展 `representations: Vec<ImportRepresentation>`：

```
hash 命中已存在条目:
  - 现有 representations 为空 → 用 archive 数据补齐，计入 imported
  - 现有 representations 非空 → 跳过 representations，沿用原有去重行为
hash 未命中 → 完整 insert
```

### 9.4 设置页可见性

设置 → 数据 区域加 caption：

```
Archive format: Clipin Clipboard Archive v2 · [Open Spec ↗]
```

链接打开独立 repo。

---

## 10. 体积控制

| 规则 | 阈值 | 触发行为 |
|---|---|---|
| 单 representation 大小 | 1 MB | 跳过该 UTI，保留条目 + 其他 representations |
| 单 item 所有 representations 总和 | 4 MB | 仅保留 plain + content，丢弃所有 representations |
| 全库 GC / TTL | 无 | 沿用现有"清空历史" + retention 设置；ON DELETE CASCADE 自动清理副表 |

设置 → 存储 caption：

```
History uses 124 MB · 3,421 items · 287 with extra formats
```

---

## 11. 测试

### 11.1 Rust 单元测试（`cargo test --lib`）

- `test_migration_v8_to_v9_creates_representations_table`
- `test_save_item_with_representations_inserts_into_subtable`
- `test_get_item_returns_representations`
- `test_delete_item_cascades_representations`（同时验证 `PRAGMA foreign_keys = ON` 在每个新 connection 都生效）
- `test_import_item_if_missing_with_representations_new`
- `test_import_item_if_missing_merges_representations_into_empty`
- `test_import_item_if_missing_skips_when_representations_exist`
- `test_size_limit_skips_oversized_representation`
- `test_size_limit_falls_back_to_plain_when_total_exceeds`

### 11.2 Swift 单元测试（XCTest）

- `testClipboardMonitor_extractsHTMLRepresentationFromRichText`
- `testClipboardMonitor_skipsRedundantPublicURLForPlainURL`
- `testClipboardMonitor_skipsBlacklistedDynamicUTIs`
- `testPasteService_writeAllRepresentations_setsMultipleUTIs`
- `testPasteService_writeRepresentation_writesSingleUTI`
- `testPasteService_writeAllRepresentations_fallsBackWhenEmpty`
- `testArchive_v2_roundtripPreservesRepresentations`
- `testArchive_v1_importIsBackwardCompatible`

### 11.3 端到端验证清单（每发版手工过一遍）

```
[ ] Notion 复制富文本 → Slack       = 富文本 (html)
[ ] Notion 复制富文本 → VSCode      = plain（目标 app 自挑）
[ ] Notion 复制富文本 → Mail        = 富文本 (rtf/html)
[ ] Notion 复制富文本 → ⇧Return → Slack = plain
[ ] Notion 复制富文本 → 动作面板 Paste as Plain → Slack = plain
[ ] 浏览器复制超链接 → Slack        = 链接 + 标题
[ ] 终端长文本复制（无富文本）       = representations 空，动作面板无 Paste as X
[ ] 5MB RTFD 复制                  = fallback 仅 plain
[ ] v1 数据库升级                  = 老条目 representations 空，列表正常
[ ] v1 archive 导入                = 不崩，representations 默认空
[ ] 重复导入同一 v2 archive         = 第二次跳过 representations
```

---

## 12. 实施顺序（每 Phase 独立可验证）

| Phase | 内容 | 用户可感知点 |
|---|---|---|
| **1** | Rust schema v9 + insert/get APIs | — |
| **2** | ClipboardMonitor 采集白名单 representations | preview metadata 显示 `Formats: plain · html · rtf` |
| **3** | PasteService writeAllRepresentations + Return 切换 | Return 全量回放生效 |
| **4** | footer pill + 动作面板 Paste as X + 键盘路由 | footer / ⌘K 全部命令可达 |
| **5** | Archive v2 export/import + 设置页 caption | 备份能跨机保留 representation |
| **6** | 首次富文本粘贴 toast notice | "Pasted with 3 formats" 一次性提示 |
| **7** | 独立 repo + 规范文档 + README 链接 | Open Spec 链接生效 |

**关键节点**：Phase 2 完成后用户已经能感知到这次升级（preview 上有 Formats 字段），即使 Return 行为还没切。Phase 3 是真实"格式无损"上线。

---

## 13. 风险与未决

| 风险 | 缓解 |
|---|---|
| 目标 app 错误地从多 UTI 中挑了 rtf 而非 html（极少数 app）| ⇧Return + 动作面板 Paste as X 兜底；首次发现时用户手动覆盖 |
| 大量历史条目升级到 v9 后副表空，磁盘碎片 | 不做回填；让用户自然替换 |
| 用户从富文本应用复制粘到 markdown 编辑器时意外保留富文本 | 取决于目标 app 实现；现代 markdown 编辑器（Bear、Obsidian）已正确取 plain |
| 公开 archive 格式后未来想破坏性升级 | schemaVersion 字段 + format URL 约定向后兼容承诺；v2 是首个公开版本，仍有调整窗口 |

---

## 14. 关联现有 CLAUDE.md 决策

- **"写剪贴板前必须先验证 payload"** — `writeRepresentation` 找不到 UTI 时不 clearContents
- **"快速粘贴 / 普通粘贴 / 纯文本粘贴必须共享真实使用语义"** — 所有新粘贴入口均 touchItem
- **"动作面板里展示出来的快捷键必须是真快捷键"** — ⌥H / ⌥R 注册到 PaletteActionShortcut.all
- **"全局统一导航必须按上下文路由"** — 新快捷键由 AppDelegate.handlePaletteKeyEvent 拦截
- **"footer 是固定高度 command strip"** — 新 pill 单行 lineLimit(1) + fixedSize
- **"用户可见文案必须本地化"** — "Paste as HTML" 等走 Localizable.strings
- **"FTS 触发器只跟随可搜索字段更新"** — 副表写入不触 FTS5

---

## 15. 后续延展（不在本期）

- image 类型扩展 representations（PDF representation from Preview 复制）
- 智能按目标 app 分流粘贴策略（终端类强制 plain / Markdown 编辑器优先 plain）
- 设置页加"代理粘贴格式"全局开关（power user：默认始终 plain，全量回放变 opt-in）
- 列表行的多格式视觉小标记
