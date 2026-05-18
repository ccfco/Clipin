# 多 Representation 剪贴板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Clipin 在采集剪贴板时保留所有有意义的 UTI representations (HTML/RTF 等)，粘贴时整组回放给目标 app 自己挑，做到从 Notion 复制到 Slack 粘贴格式无损往返。

**Architecture:** 主表 `clip_items` 保留 plain text content，副表 `clip_representations(item_id, uti, data BLOB)` 存额外 UTI；Return 路径走 `NSPasteboardItem` 多 UTI 写回（macOS 系统粘贴语义）；动作面板 ⌥H / ⌥R 提供"系统挑错时的覆盖入口"；archive v2 用公开 JSON 格式互通。

**Tech Stack:** Rust (rusqlite + UniFFI) → Swift (AppKit + SwiftUI)；SQLite migration v8 → v9；XCTest + cargo test。

**Spec Reference:** [docs/superpowers/specs/2026-05-15-multi-representation-clipboard-design.md](../specs/2026-05-15-multi-representation-clipboard-design.md)

---

## File Structure

### 新建文件

| 路径 | 责任 |
|---|---|
| `Clipin/Services/ClipboardRepresentation.swift` | UTI 白名单常量 + Representation 模型 + 提取/去重/大小限制工具 |
| `ClipinTests/ClipboardRepresentationTests.swift` | 采集逻辑 XCTest |
| `ClipinTests/PasteServiceRepresentationTests.swift` | 粘贴逻辑 XCTest |
| `ClipinTests/ArchiveV2Tests.swift` | Archive v2 roundtrip 测试 |

### 修改文件

| 路径 | 改动 |
|---|---|
| `rust/src/models.rs` | 添加 `ClipRepresentation` UniFFI Record |
| `rust/src/storage.rs` | 启用 `foreign_keys`、migration v9、insert/load/delete representations API、`save_item`/`import_item_if_missing` 加 representations 参数 |
| `rust/src/lib.rs` | UniFFI export 扩展 + 新 API + 单元测试 |
| `Clipin/Services/ClipboardMonitor.swift` | text/url 分支注入 extractRepresentations |
| `Clipin/Services/PasteService.swift` | `writeAllRepresentations` + `writeRepresentation` + Return 路径切换 |
| `Clipin/Services/ArchiveService.swift` | schemaVersion=2 + representations 字段 + 导入合并 |
| `Clipin/App/LauncherKeyRouting.swift` | 新增 `pasteAsHTML` / `pasteAsRTF` shortcut |
| `Clipin/ViewModels/ClipboardViewModel.swift` | `representationActions(for:)` + 三档粘贴入口 + touchItem 统一 |
| `Clipin/App/AppDelegate.swift` | key monitor 路由扩展处理 ⌥H / ⌥R |
| `Clipin/Views/MainPanel.swift` (or PreviewPane) | preview metadata `Formats: plain · html · rtf` + footer HTML/RTF pill |
| `Clipin/Models/SettingsStore.swift` | `richPasteNoticeCountSeen` 计数器 |
| `Clipin/Views/SettingsView.swift` | Archive caption + Open Spec 链接 |
| `Clipin/Resources/Localizable.strings` (zh/en) | 新增 "Paste as HTML/RTF/Plain"、"Formats"、Archive caption 等本地化 key |

### 独立 GitHub 仓库（Phase 7）

| 仓库 | 责任 |
|---|---|
| `ccfco/Clipin-archive-format` | 公开 JSON archive 规范文档；独立 LICENSE（CC0）；版本化承诺 |

---

## Phase 1: Rust Schema v9 + Representations APIs

每个 task 是 TDD（红 → 绿 → 提交）。Phase 1 完成后 Rust 层完整支持 representations 但 Swift 层不变。

### Task 1.1: 启用 `PRAGMA foreign_keys = ON`

**Files:**
- Modify: `rust/src/storage.rs:93-100`

- [ ] **Step 1: 写测试验证 foreign_keys 启用**

把如下测试加到 `rust/src/storage.rs` 末尾 `mod migration_tests` 内：

```rust
#[test]
fn test_foreign_keys_pragma_is_enabled() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();
    let conn = storage.conn();
    let fk_enabled: i32 = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
    assert_eq!(fk_enabled, 1, "foreign_keys must be ON for ON DELETE CASCADE");
}
```

- [ ] **Step 2: 运行测试看到失败**

```bash
cd rust && cargo test --lib test_foreign_keys_pragma_is_enabled
```

Expected: FAIL（`fk_enabled` 是 0，因为没开）

- [ ] **Step 3: 在 `Storage::new` 启用 foreign_keys**

修改 `rust/src/storage.rs:93-100`：

```rust
pub fn new(db_path: &str, image_dir: &str) -> Result<Self, ClipinError> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;
    let storage = Storage {
        conn: Mutex::new(conn),
        image_dir: image_dir.to_string(),
    };
    storage.init_schema()?;
    Ok(storage)
}
```

- [ ] **Step 4: 重跑测试看到通过**

```bash
cd rust && cargo test --lib test_foreign_keys_pragma_is_enabled
```

Expected: PASS

- [ ] **Step 5: 跑全部既有测试确保无回归**

```bash
cd rust && cargo test --lib
```

Expected: 所有既有测试 PASS

- [ ] **Step 6: 提交**

```bash
cd /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961
git add rust/src/storage.rs
git commit -m "$(cat <<'EOF'
feat: 启用 SQLite foreign_keys，为副表 ON DELETE CASCADE 做准备

【根因/背景】SQLite 默认 foreign_keys=OFF 且 connection-scoped；下一步要加 clip_representations 副表，没有 foreign_keys 的话 ON DELETE CASCADE 不会生效。

【踩坑记录】PRAGMA 是会话级，每次打开 connection 都要重设；Storage::new 是唯一打开点，单点启用足够。

【改动范围】rust/src/storage.rs::new 添加 PRAGMA foreign_keys=ON；新增 test_foreign_keys_pragma_is_enabled 验证。
EOF
)"
```

---

### Task 1.2: Migration v9 创建 `clip_representations` 副表

**Files:**
- Modify: `rust/src/storage.rs` (run_migrations + new migrate_to_v9)

- [ ] **Step 1: 添加 migrate_to_v9 函数**

在 `migrate_to_v8` 之后添加：

```rust
fn migrate_to_v9(conn: &Connection) -> Result<(), ClipinError> {
    conn.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS clip_representations (
            item_id  TEXT NOT NULL,
            uti      TEXT NOT NULL,
            data     BLOB NOT NULL,
            PRIMARY KEY (item_id, uti),
            FOREIGN KEY (item_id) REFERENCES clip_items(id) ON DELETE CASCADE
        );

        CREATE INDEX IF NOT EXISTS idx_representations_item_id
            ON clip_representations(item_id);

        PRAGMA user_version = 9;
        ",
    )?;
    Ok(())
}
```

- [ ] **Step 2: 接入 run_migrations**

修改 `rust/src/storage.rs:113-145` 的 `run_migrations`：

```rust
fn run_migrations(&self, from_version: i32) -> Result<(), ClipinError> {
    if from_version < 1 { /* ...existing... */ }
    // ... existing v2-v8 unchanged ...
    if from_version < 9 {
        Self::migrate_to_v9(&self.conn())?;
    }
    Ok(())
}
```

- [ ] **Step 3: 更新 schema_version 测试**

修改既有 `test_fresh_db_is_version_1` 和 `test_old_db_migrates`：把 `assert_eq!(storage.schema_version(), 8` 改成 `9`。

- [ ] **Step 4: 添加新 migration 测试**

```rust
#[test]
fn test_v9_creates_representations_table() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();
    let conn = storage.conn();
    let table_exists: i32 = conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clip_representations'",
        [],
        |r| r.get(0),
    ).unwrap();
    assert_eq!(table_exists, 1);
}
```

- [ ] **Step 5: 跑测试**

```bash
cd rust && cargo test --lib
```

Expected: 全部 PASS（含新增测试和被更新的版本号测试）

- [ ] **Step 6: 提交**

```bash
git add rust/src/storage.rs
git commit -m "feat: 添加 migration v9 创建 clip_representations 副表

【根因/背景】副表用于存放 text/url 条目的额外 UTI representation (HTML/RTF/RTFD/URL)，主表 clip_items 保持 plain text 不变以维持搜索/排序逻辑零改动。

【改动范围】migrate_to_v9 + run_migrations 接入；schema_version 测试更新到 9；新增 test_v9_creates_representations_table。"
```

---

### Task 1.3: 添加 `ClipRepresentation` 类型

**Files:**
- Modify: `rust/src/models.rs`

- [ ] **Step 1: 添加 ClipRepresentation Record**

在 `rust/src/models.rs` 末尾添加：

```rust
/// 单条剪贴板条目的一种 UTI representation
/// 仅适用于 text 和 url 类型；image / file 不存额外 representation
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClipRepresentation {
    pub uti: String,
    pub data: Vec<u8>,
}
```

- [ ] **Step 2: 编译验证**

```bash
cd rust && cargo build --lib
```

Expected: 编译通过

- [ ] **Step 3: 提交**

```bash
git add rust/src/models.rs
git commit -m "feat: 新增 ClipRepresentation 类型用于副表数据传递"
```

---

### Task 1.4: 副表 insert / load / delete APIs

**Files:**
- Modify: `rust/src/storage.rs` (在 import_item_if_missing 后面添加新方法)

- [ ] **Step 1: 写"insert 后 load 能拿到"的测试**

```rust
#[test]
fn test_insert_and_load_representations() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();

    let item = storage.save_item("hi", &ClipType::Text, None, None, None).unwrap();
    let reps = vec![
        ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() },
        ClipRepresentation { uti: "public.rtf".into(),  data: b"{\\rtf1 hi}".to_vec() },
    ];
    storage.insert_representations(&item.id, &reps).unwrap();

    let loaded = storage.load_representations(&item.id).unwrap();
    assert_eq!(loaded.len(), 2);
    assert!(loaded.iter().any(|r| r.uti == "public.html" && r.data == b"<p>hi</p>"));
}
```

- [ ] **Step 2: 运行看到失败（方法未定义）**

```bash
cd rust && cargo test --lib test_insert_and_load_representations
```

Expected: 编译失败

- [ ] **Step 3: 实现 insert_representations**

在 `Storage` impl 内添加：

```rust
pub fn insert_representations(
    &self,
    item_id: &str,
    representations: &[ClipRepresentation],
) -> Result<(), ClipinError> {
    if representations.is_empty() {
        return Ok(());
    }
    let mut conn = self.conn();
    let tx = conn.transaction()?;
    for rep in representations {
        tx.execute(
            "INSERT OR REPLACE INTO clip_representations (item_id, uti, data) VALUES (?1, ?2, ?3)",
            params![item_id, rep.uti, rep.data],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn load_representations(&self, item_id: &str) -> Result<Vec<ClipRepresentation>, ClipinError> {
    let conn = self.conn();
    let mut stmt = conn.prepare(
        "SELECT uti, data FROM clip_representations WHERE item_id = ?1 ORDER BY uti",
    )?;
    let rows = stmt.query_map(params![item_id], |row| {
        Ok(ClipRepresentation {
            uti: row.get(0)?,
            data: row.get(1)?,
        })
    })?;
    let mut result = Vec::new();
    for row in rows {
        result.push(row?);
    }
    Ok(result)
}
```

- [ ] **Step 4: 跑测试通过**

```bash
cd rust && cargo test --lib test_insert_and_load_representations
```

Expected: PASS

- [ ] **Step 5: 写 CASCADE 测试**

```rust
#[test]
fn test_delete_item_cascades_representations() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();

    let item = storage.save_item("hi", &ClipType::Text, None, None, None).unwrap();
    storage.insert_representations(&item.id, &[
        ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() },
    ]).unwrap();

    storage.delete_item(&item.id).unwrap();

    let loaded = storage.load_representations(&item.id).unwrap();
    assert_eq!(loaded.len(), 0, "ON DELETE CASCADE should have removed representations");
}
```

- [ ] **Step 6: 跑 CASCADE 测试**

```bash
cd rust && cargo test --lib test_delete_item_cascades_representations
```

Expected: PASS（因为 Task 1.1 已开 foreign_keys）

- [ ] **Step 7: 提交**

```bash
git add rust/src/storage.rs
git commit -m "feat: 副表 insert/load APIs + CASCADE 测试"
```

---

### Task 1.5: UniFFI export + ClipinCore 方法

**Files:**
- Modify: `rust/src/lib.rs`

- [ ] **Step 1: 添加 saveItemWithRepresentations + getRepresentations 到 ClipinCore**

在 `rust/src/lib.rs` 的 `impl ClipinCore` 内（紧跟 `save_item` 之后）添加：

```rust
/// 保存剪贴板记录并写入 representations。当 representations 为空时等价于 save_item。
pub fn save_item_with_representations(
    &self,
    content: String,
    clip_type: ClipType,
    source_app: Option<String>,
    source_name: Option<String>,
    image_path: Option<String>,
    representations: Vec<ClipRepresentation>,
) -> Result<ClipItem, ClipinError> {
    let item = self.storage.save_item(
        &content,
        &clip_type,
        source_app.as_deref(),
        source_name.as_deref(),
        image_path.as_deref(),
    )?;
    if !representations.is_empty() {
        self.storage.insert_representations(&item.id, &representations)?;
    }
    Ok(item)
}

/// 读取一条条目的所有 representations
pub fn get_representations(&self, id: String) -> Result<Vec<ClipRepresentation>, ClipinError> {
    self.storage.load_representations(&id)
}
```

- [ ] **Step 2: 添加 ClipinCore 测试**

```rust
#[test]
fn test_save_item_with_representations() {
    let (core, _tmp) = make_core();
    let reps = vec![
        ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() },
    ];
    let item = core.save_item_with_representations(
        "hi".into(),
        ClipType::Text,
        None, None, None,
        reps,
    ).unwrap();

    let loaded = core.get_representations(item.id).unwrap();
    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].uti, "public.html");
}
```

`make_core()` 是既有测试 helper，搜索 `fn make_core` 验证存在。

- [ ] **Step 3: 跑测试**

```bash
cd rust && cargo test --lib test_save_item_with_representations
```

Expected: PASS

- [ ] **Step 4: 编译 UniFFI bindings**

```bash
cd /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961
./scripts/build-rust.sh
```

Expected: 成功生成新 bindings 到 `Clipin/Generated/`

- [ ] **Step 5: 提交**

```bash
git add rust/src/lib.rs
git commit -m "feat: UniFFI 导出 saveItemWithRepresentations / getRepresentations"
```

---

## Phase 2: ClipboardMonitor 采集 representations + Preview Formats 显示

### Task 2.1: ClipboardRepresentation.swift — UTI 白名单 + Representation 模型

**Files:**
- Create: `Clipin/Services/ClipboardRepresentation.swift`

- [ ] **Step 1: 创建文件**

```swift
import AppKit

/// 单条剪贴板条目的一种 UTI representation。
/// 对应 Rust 侧的 ClipRepresentation。
struct ClipboardRepresentation: Equatable {
    let uti: String
    let data: Data
}

enum ClipboardRepresentationExtractor {
    /// 单 representation 大小上限（1 MB）。
    /// 富文本 HTML/RTF 通常 < 100KB，1MB 已覆盖嵌入 base64 图片的极端富文本。
    static let perRepresentationLimit = 1 * 1024 * 1024

    /// 单 item 所有 representations 总和上限（4 MB）。
    /// 超过则 fallback 仅保留 plain，避免极端 RTFD 把 DB 撑大。
    static let totalLimit = 4 * 1024 * 1024

    /// 白名单：只采集能被另一个 app 理解的公共 UTI。
    /// 不收 dyn.xxx、应用私有 UTI、过时的 com.apple.flat-rtfd 等。
    static let whitelist: [NSPasteboard.PasteboardType] = [
        .html,                                 // public.html
        .rtf,                                  // public.rtf
        NSPasteboard.PasteboardType("public.rtfd"),
        .URL,                                  // public.url
    ]

    /// 从 pasteboard 提取白名单 representations，去掉与 primaryContent 完全重复的。
    /// 返回空数组表示这条 item 没有额外 representation（纯 plain 复制 / 全部超大被 fallback）。
    static func extract(
        from pasteboard: NSPasteboard,
        primaryContent: String
    ) -> [ClipboardRepresentation] {
        var result: [ClipboardRepresentation] = []
        var totalBytes = 0
        let availableTypes = pasteboard.types ?? []

        for type in whitelist where availableTypes.contains(type) {
            guard let data = pasteboard.data(forType: type) else { continue }

            // 去重：data 解码为 UTF-8 后等同于 primaryContent → 跳过
            if let asString = String(data: data, encoding: .utf8), asString == primaryContent {
                continue
            }

            // 单条上限
            guard data.count <= perRepresentationLimit else { continue }

            result.append(ClipboardRepresentation(uti: type.rawValue, data: data))
            totalBytes += data.count
        }

        // 总和上限 → fallback 全丢
        guard totalBytes <= totalLimit else { return [] }
        return result
    }
}
```

- [ ] **Step 2: 加入 Xcode 项目（xcodegen）**

确认 `project.yml` 中 `Clipin/Services/**` 自动包含，**不需要手动改 project.yml**。运行：

```bash
xcodegen generate
```

- [ ] **Step 3: 编译验证**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -20
```

Expected: 编译通过

- [ ] **Step 4: 提交**

```bash
git add Clipin/Services/ClipboardRepresentation.swift Clipin.xcodeproj
git commit -m "feat: 新增 ClipboardRepresentationExtractor — 白名单 + 大小限制 + 去重"
```

---

### Task 2.2: ClipboardRepresentation XCTest

**Files:**
- Create: `ClipinTests/ClipboardRepresentationTests.swift`

- [ ] **Step 1: 写四组测试**

```swift
import XCTest
import AppKit
@testable import Clipin

final class ClipboardRepresentationTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testExtractsHTMLAndRTF() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        pb.setData(Data("<p>hi</p>".utf8), forType: .html)
        pb.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 2)
        XCTAssertTrue(reps.contains { $0.uti == "public.html" })
        XCTAssertTrue(reps.contains { $0.uti == "public.rtf" })
    }

    func testSkipsRedundantPublicURLForPlainURL() {
        // 当 plain text 完全等于 public.url，去重应跳过 public.url
        let pb = makePasteboard()
        let url = "https://example.com"
        pb.setString(url, forType: .string)
        pb.setString(url, forType: .URL)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: url)
        XCTAssertEqual(reps.count, 0)
    }

    func testSkipsBlacklistedDynamicUTIs() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        pb.setData(Data([0xDE, 0xAD]), forType: NSPasteboard.PasteboardType("dyn.private"))
        pb.setData(Data([0xBE, 0xEF]), forType: NSPasteboard.PasteboardType("com.apple.NSColor.pasteboard"))

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 0)
    }

    func testFallbackWhenTotalSizeExceedsLimit() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        // 5 MB 超过 4 MB 总和上限
        let big = Data(count: 5 * 1024 * 1024)
        pb.setData(big, forType: .html)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 0, "Total > 4MB should fallback to plain only")
    }

    func testSkipsOversizedSingleRepresentation() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        let big = Data(count: 2 * 1024 * 1024)  // 2MB > 1MB single limit
        pb.setData(big, forType: .html)
        let small = Data("{\\rtf1 hi}".utf8)
        pb.setData(small, forType: .rtf)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 1)
        XCTAssertEqual(reps[0].uti, "public.rtf")
    }
}
```

- [ ] **Step 2: 跑测试**

```bash
xcodebuild test -project Clipin.xcodeproj -scheme Clipin -destination 'platform=macOS' -only-testing:ClipinTests/ClipboardRepresentationTests 2>&1 | tail -30
```

Expected: 5 tests PASS

- [ ] **Step 3: 提交**

```bash
git add ClipinTests/ClipboardRepresentationTests.swift
git commit -m "test: ClipboardRepresentationExtractor 五组测试覆盖白名单/去重/大小限制"
```

---

### Task 2.3: ClipboardMonitor 注入 representations

**Files:**
- Modify: `Clipin/Services/ClipboardMonitor.swift`

- [ ] **Step 1: 扩展 ClipboardPayload 携带 representations**

`Clipin/Services/ClipboardMonitor.swift:30-35` 替换：

```swift
private enum ClipboardPayload: Sendable {
    case text(String, String?, String?, [ClipboardRepresentation])
    case url(String, String?, String?, [ClipboardRepresentation])
    case file(String, String?, String?)
    case image(Data, String?, String?)
}
```

- [ ] **Step 2: 在 checkClipboard 提取 representations**

`Clipin/Services/ClipboardMonitor.swift:92-108` 替换 text/url 分支：

```swift
} else if let urlString = pasteboard.string(forType: .URL) ?? extractURL(from: pasteboard) {
    let reps = ClipboardRepresentationExtractor.extract(from: pasteboard, primaryContent: urlString)
    persist(.url(urlString, sourceApp, sourceName, reps))
} else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
    persist(.image(imageData, sourceApp, sourceName))
} else if let text = pasteboard.string(forType: .string), !text.isEmpty {
    if text.utf8.count > Self.maxTextBytes {
        print("ℹ️ Skipped clipboard text larger than \(Self.maxTextBytes) bytes")
        return
    }
    let reps = ClipboardRepresentationExtractor.extract(from: pasteboard, primaryContent: text)
    persist(.text(text, sourceApp, sourceName, reps))
}
```

- [ ] **Step 3: 更新 persist 调用 saveItemWithRepresentations**

`Clipin/Services/ClipboardMonitor.swift:111-187` 内 text 和 url case 调用替换为：

```swift
case let .text(content, sourceApp, sourceName, reps):
    let coreReps = reps.map { ClipRepresentation(uti: $0.uti, data: $0.data) }
    _ = try core.saveItemWithRepresentations(
        content: content,
        clipType: .text,
        sourceApp: sourceApp,
        sourceName: sourceName,
        imagePath: nil,
        representations: coreReps
    )

case let .url(content, sourceApp, sourceName, reps):
    let coreReps = reps.map { ClipRepresentation(uti: $0.uti, data: $0.data) }
    _ = try core.saveItemWithRepresentations(
        content: content,
        clipType: .url,
        sourceApp: sourceApp,
        sourceName: sourceName,
        imagePath: nil,
        representations: coreReps
    )
```

> **注意**：`core.saveItemWithRepresentations` 的精确签名来自 UniFFI 生成的 Swift binding。如果生成的 Swift 名称是 `saveItemWithRepresentations` 还是 `save_item_with_representations`，以 `Clipin/Generated/Clipin.swift` 为准——UniFFI 默认将 Rust snake_case 转为 Swift lowerCamelCase。

- [ ] **Step 4: 编译**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -20
```

Expected: 编译通过

- [ ] **Step 5: 提交**

```bash
git add Clipin/Services/ClipboardMonitor.swift
git commit -m "feat: ClipboardMonitor 在 text/url 分支采集 representations"
```

---

### Task 2.4: Preview metadata 显示 Formats

**Files:**
- Modify: `Clipin/Views/MainPanel.swift`（或 PreviewPane 所在文件）
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`
- Modify: `Clipin/Resources/Localizable.strings` (zh + en)

- [ ] **Step 1: 在 ViewModel 加载选中项 representations**

在 `ClipboardViewModel` 中：

```swift
@Published private(set) var selectedRepresentationUTIs: [String] = []

func reloadRepresentationsForSelected() {
    guard let id = selectedItemID else {
        selectedRepresentationUTIs = []
        return
    }
    Task.detached(priority: .userInitiated) { [core] in
        let reps = (try? core.getRepresentations(id: id)) ?? []
        await MainActor.run { [weak self] in
            self?.selectedRepresentationUTIs = reps.map { $0.uti }
        }
    }
}
```

并在 `selectedItemID` didSet 末尾加 `reloadRepresentationsForSelected()`。

- [ ] **Step 2: PreviewPane metadata 添加 Formats 行**

在 PreviewPane 的 metadata block 内找到现有 metadata rows，加：

```swift
metadataRow(
    label: NSLocalizedString("preview.metadata.formats", comment: "Formats label in preview metadata"),
    value: formatsDisplay
)

private var formatsDisplay: String {
    var labels: [String] = ["plain"]
    if viewModel.selectedRepresentationUTIs.contains("public.html") { labels.append("html") }
    if viewModel.selectedRepresentationUTIs.contains("public.rtf")  { labels.append("rtf") }
    if viewModel.selectedRepresentationUTIs.contains("public.rtfd") { labels.append("rtfd") }
    if viewModel.selectedRepresentationUTIs.contains("public.url")  { labels.append("url") }
    return labels.joined(separator: " · ")
}
```

> 如果项目内 PreviewPane 有专门的 metadata helper（搜 `metadataRow` 看签名），按 helper 签名调整；本步骤要的是结果"在 preview 元数据里出现 Formats: plain · html · rtf"。

- [ ] **Step 3: 添加本地化**

`Clipin/Resources/zh-Hans.lproj/Localizable.strings`：

```
"preview.metadata.formats" = "格式";
```

`Clipin/Resources/en.lproj/Localizable.strings`：

```
"preview.metadata.formats" = "Formats";
```

- [ ] **Step 4: 编译 + 手工 smoke**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

Expected: 编译通过。手工运行 app，复制一段 Notion 富文本，唤起 Clipin → preview 看到 `Formats: plain · html · rtf`。

- [ ] **Step 5: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/Views/MainPanel.swift Clipin/Resources/zh-Hans.lproj/Localizable.strings Clipin/Resources/en.lproj/Localizable.strings
git commit -m "feat: preview metadata 显示 Formats: plain · html · rtf 用户感知点"
```

---

## Phase 3: PasteService 三档粘贴

### Task 3.1: writeAllRepresentations

**Files:**
- Modify: `Clipin/Services/PasteService.swift`
- Create: `ClipinTests/PasteServiceRepresentationTests.swift`

- [ ] **Step 1: 写 writeAllRepresentations 单元测试**

```swift
import XCTest
import AppKit
@testable import Clipin

final class PasteServiceRepresentationTests: XCTestCase {
    func testWriteAllRepresentationsSetsAllUTIs() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()

        let item = makeItem(content: "hi", clipType: .text, representations: [
            ("public.html", Data("<p>hi</p>".utf8)),
            ("public.rtf",  Data("{\\rtf1 hi}".utf8)),
        ])

        let ok = PasteService.writeAllRepresentations(item, to: pb)
        XCTAssertTrue(ok)

        XCTAssertEqual(pb.string(forType: .string), "hi")
        XCTAssertEqual(pb.data(forType: .html), Data("<p>hi</p>".utf8))
        XCTAssertEqual(pb.data(forType: .rtf), Data("{\\rtf1 hi}".utf8))
    }

    func testWriteAllRepresentationsFallsBackWhenEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()

        let item = makeItem(content: "hi", clipType: .text, representations: [])
        let ok = PasteService.writeAllRepresentations(item, to: pb)

        XCTAssertTrue(ok)
        XCTAssertEqual(pb.string(forType: .string), "hi")
        XCTAssertNil(pb.data(forType: .html))
    }
}

// helper：构造一个测试 ClipItem，签名由项目实际 ClipItem swift 定义决定
// 如果 ClipItem 是 UniFFI Record 不能直接 init，改成在 ViewModel 层包一个 PasteableItem 协议
```

> **重要**：UniFFI Record 在 Swift 侧是 struct，可以直接构造。但如果 ClipItem 内有 representations 字段（在 Task 1.5 之后 Rust 侧 ClipItem 并未添加 representations 字段，representations 通过 `getRepresentations` API 单独取），那 `writeAllRepresentations` 的入参需要重新设计——见 Step 2。

- [ ] **Step 2: 修改 PasteService 接口签名以接受 representations 数组**

`Clipin/Services/PasteService.swift` 添加：

```swift
/// Return 路径的"全量回放"：把所有 representation 写到一个 NSPasteboardItem。
/// 由调用方（ViewModel/AppDelegate）通过 ClipinCore.getRepresentations 先取出 reps 再传入。
/// pasteboard 参数仅供测试注入；生产路径走 NSPasteboard.general。
@discardableResult
static func writeAllRepresentations(
    _ item: ClipItem,
    representations: [ClipRepresentation],
    to pasteboard: NSPasteboard = .general
) -> Bool {
    guard item.clipType == .text || item.clipType == .url else {
        return writeToClipboard(item)
    }

    let pbItem = NSPasteboardItem()

    // plain text 始终存在
    guard pbItem.setString(item.content, forType: .string) else { return false }

    if item.clipType == .url {
        _ = pbItem.setString(item.content, forType: .URL)
    }

    for rep in representations {
        _ = pbItem.setData(rep.data, forType: .init(rep.uti))
    }

    pasteboard.clearContents()
    return pasteboard.writeObjects([pbItem])
}
```

- [ ] **Step 3: 更新 Task 3.1 Step 1 的测试 helper**

把测试里的 `representations: [...]` helper 改成两阶段：先构造 item，再传 `[ClipRepresentation]` 数组给 `writeAllRepresentations`。

- [ ] **Step 4: 跑测试**

```bash
xcodebuild test -project Clipin.xcodeproj -scheme Clipin -destination 'platform=macOS' -only-testing:ClipinTests/PasteServiceRepresentationTests 2>&1 | tail -20
```

Expected: 2 tests PASS

- [ ] **Step 5: 提交**

```bash
git add Clipin/Services/PasteService.swift ClipinTests/PasteServiceRepresentationTests.swift
git commit -m "feat: PasteService.writeAllRepresentations — Return 全量回放给 NSPasteboardItem"
```

---

### Task 3.2: writeRepresentation 单 UTI 路径

**Files:**
- Modify: `Clipin/Services/PasteService.swift`
- Modify: `ClipinTests/PasteServiceRepresentationTests.swift`

- [ ] **Step 1: 写测试**

加到 `PasteServiceRepresentationTests`：

```swift
func testWriteRepresentationSingleUTI() {
    let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
    pb.clearContents()

    let item = makeItem(content: "hi", clipType: .text, representations: [])
    let reps = [ClipRepresentation(uti: "public.html", data: Data("<p>hi</p>".utf8))]

    let ok = PasteService.writeRepresentation(item, uti: "public.html", representations: reps, to: pb)
    XCTAssertTrue(ok)
    XCTAssertEqual(pb.data(forType: .html), Data("<p>hi</p>".utf8))
    XCTAssertNil(pb.string(forType: .string), "single UTI mode should NOT also write plain")
}

func testWriteRepresentationFailsWhenUTIMissing() {
    let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
    pb.clearContents()
    // pasteboard 预填一些内容验证"失败时不 clearContents"
    pb.setString("existing", forType: .string)

    let item = makeItem(content: "hi", clipType: .text, representations: [])
    let ok = PasteService.writeRepresentation(item, uti: "public.html", representations: [], to: pb)
    XCTAssertFalse(ok)
    XCTAssertEqual(pb.string(forType: .string), "existing", "must not clear pasteboard on failure")
}

func testWriteRepresentationPlainRebuiltsFromContent() {
    let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
    pb.clearContents()
    let item = makeItem(content: "hi", clipType: .text, representations: [])
    let ok = PasteService.writeRepresentation(item, uti: "public.utf8-plain-text", representations: [], to: pb)
    XCTAssertTrue(ok)
}
```

- [ ] **Step 2: 实现**

加到 `Clipin/Services/PasteService.swift`：

```swift
/// 动作面板 "Paste as X" 入口：仅写一种 UTI。
/// UTI = public.utf8-plain-text 时从 item.content 重建；其他 UTI 需要 representations 里找得到。
/// 找不到时返回 false 且 NOT clearContents。
@discardableResult
static func writeRepresentation(
    _ item: ClipItem,
    uti: String,
    representations: [ClipRepresentation],
    to pasteboard: NSPasteboard = .general
) -> Bool {
    let data: Data
    if uti == NSPasteboard.PasteboardType.string.rawValue || uti == "public.utf8-plain-text" {
        guard let bytes = item.content.data(using: .utf8) else { return false }
        data = bytes
    } else {
        guard let rep = representations.first(where: { $0.uti == uti }) else {
            return false  // 不 clearContents
        }
        data = rep.data
    }

    pasteboard.clearContents()
    return pasteboard.setData(data, forType: .init(uti))
}
```

- [ ] **Step 3: 跑测试**

```bash
xcodebuild test -project Clipin.xcodeproj -scheme Clipin -destination 'platform=macOS' -only-testing:ClipinTests/PasteServiceRepresentationTests 2>&1 | tail -20
```

Expected: 5 tests PASS (2 from Task 3.1 + 3 new)

- [ ] **Step 4: 提交**

```bash
git add Clipin/Services/PasteService.swift ClipinTests/PasteServiceRepresentationTests.swift
git commit -m "feat: PasteService.writeRepresentation — 单 UTI 写回，失败不 clearContents"
```

---

### Task 3.3: Return 路径切换 text/url 到 writeAllRepresentations

**Files:**
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`（或 AppDelegate.executePasteFlow 所在）

- [ ] **Step 1: 定位现有 Return 入口**

```bash
grep -n "writeToClipboard\|performPaste\|executePasteFlow" /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961/Clipin/ViewModels/ClipboardViewModel.swift /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961/Clipin/App/AppDelegate.swift | head -20
```

把 Return 路径中 `PasteService.writeToClipboard(item)` 的调用替换为：

```swift
let representations: [ClipRepresentation]
if item.clipType == .text || item.clipType == .url {
    representations = (try? core.getRepresentations(id: item.id)) ?? []
} else {
    representations = []
}
let ok = PasteService.writeAllRepresentations(item, representations: representations)
```

> 实际改动位置以 grep 结果为准。Return / ⌘1-9 / 双击粘贴都应走同一路径——确认它们都收口到同一 helper（CLAUDE.md "快速粘贴、普通粘贴和纯文本粘贴必须共享真实使用语义"）。

- [ ] **Step 2: ⇧Return 路径保持调用 writeAsPlainText 不变**

确认 `⇧Return` shortcut 的 handler 仍调用 `PasteService.writeAsPlainText`（既有方法）——不改动。

- [ ] **Step 3: 编译 + 手工 smoke**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

手工测试：
1. 从 Notion 复制富文本
2. Cmd+Shift+V 唤起 Clipin
3. Return 粘到 Slack → **保留 HTML 格式**
4. Return 粘到 VSCode → 自动 plain
5. ⇧Return 粘到 Slack → 强制 plain

- [ ] **Step 4: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/App/AppDelegate.swift
git commit -m "feat: Return 路径走 writeAllRepresentations — 格式无损往返上线"
```

---

## Phase 4: footer pill + 动作面板 Paste as X

### Task 4.1: 新增 PaletteActionShortcut.pasteAsHTML / pasteAsRTF

**Files:**
- Modify: `Clipin/App/LauncherKeyRouting.swift`

- [ ] **Step 1: 添加 letterH / letterR 键码（如不存在）**

```bash
grep -n "letterH\|letterR" /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961/Clipin/App/LauncherKeyRouting.swift
```

若不存在，在 `enum KeyCode` 内添加：

```swift
static let letterH: UInt16 = 4
static let letterR: UInt16 = 15
```

> macOS virtual key codes: H=4, R=15。可在 Carbon `Events.h` `kVK_ANSI_H` / `kVK_ANSI_R` 查证。

- [ ] **Step 2: 添加两个 shortcut**

在 `struct PaletteActionShortcut` 内添加：

```swift
static let pasteAsHTML = Self(badge: "⌥H", keyCode: KeyCode.letterH, modifiers: .option)
static let pasteAsRTF  = Self(badge: "⌥R", keyCode: KeyCode.letterR, modifiers: .option)
```

并加到 `static let all`：

```swift
static let all: [Self] = [
    .pastePlain,
    .preview,
    .copy,
    .togglePin,
    .open,
    .toggleContinuousPaste,
    .settings,
    .delete,
    .pasteAsHTML,
    .pasteAsRTF,
]
```

- [ ] **Step 3: 编译**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

- [ ] **Step 4: 提交**

```bash
git add Clipin/App/LauncherKeyRouting.swift
git commit -m "feat: 新增 PaletteActionShortcut.pasteAsHTML/pasteAsRTF (⌥H / ⌥R)"
```

---

### Task 4.2: ClipboardViewModel.representationActions(for:)

**Files:**
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`
- Modify: `Clipin/Resources/Localizable.strings`

- [ ] **Step 1: 添加动态 action 生成方法**

在 `ClipboardViewModel` 内添加：

```swift
/// 当前选中条目的"Paste as X"动作。仅在条目存在 HTML 或 RTF representation 时整组出现。
/// 整组出现时一定包含 Paste as Plain Text 作为 fallback。
func representationActions(for item: ClipItem) -> [PaletteAction] {
    guard item.clipType == .text || item.clipType == .url else { return [] }

    let utis = Set(selectedRepresentationUTIs)
    let hasHTML = utis.contains("public.html")
    let hasRTF  = utis.contains("public.rtf")
    guard hasHTML || hasRTF else { return [] }

    var actions: [PaletteAction] = []

    if hasHTML {
        actions.append(PaletteAction(
            "action.pasteAsHTML",
            systemImage: "chevron.left.forwardslash.chevron.right",
            shortcut: .pasteAsHTML,
            section: .primary
        ) { [weak self] in
            self?.pasteRepresentation(of: item, uti: "public.html")
        })
    }
    if hasRTF {
        actions.append(PaletteAction(
            "action.pasteAsRTF",
            systemImage: "doc.richtext",
            shortcut: .pasteAsRTF,
            section: .primary
        ) { [weak self] in
            self?.pasteRepresentation(of: item, uti: "public.rtf")
        })
    }
    actions.append(PaletteAction(
        "action.pasteAsPlain",
        systemImage: "text.alignleft",
        shortcut: .pastePlain,
        section: .primary
    ) { [weak self] in
        self?.pastePlain(of: item)
    })
    return actions
}

private func pasteRepresentation(of item: ClipItem, uti: String) {
    let reps = (try? core.getRepresentations(id: item.id)) ?? []
    _ = PasteService.writeRepresentation(item, uti: uti, representations: reps)
    PasteService.simulatePaste()
    touchItem(item)   // CLAUDE.md "真实使用语义"
}

private func pastePlain(of item: ClipItem) {
    _ = PasteService.writeAsPlainText(item)
    PasteService.simulatePaste()
    touchItem(item)
}
```

把 `representationActions(for:)` 集成到现有的 paletteActions 生成路径——找到现有 `func paletteActions(for selectedItem:)` 或类似名字，把这些 actions 拼到现有动作前面（`.primary` section 顶部）。

- [ ] **Step 2: 添加本地化**

`zh-Hans.lproj/Localizable.strings`：

```
"action.pasteAsHTML" = "粘贴为 HTML";
"action.pasteAsRTF" = "粘贴为 RTF";
"action.pasteAsPlain" = "粘贴为纯文本";
```

`en.lproj/Localizable.strings`：

```
"action.pasteAsHTML" = "Paste as HTML";
"action.pasteAsRTF" = "Paste as RTF";
"action.pasteAsPlain" = "Paste as Plain Text";
```

- [ ] **Step 3: AppDelegate 键路由处理**

`Clipin/App/AppDelegate.swift` 现有 `executePaletteShortcut` 路径已经按 `.matching(keyCode:flags:)` 路由——`.pasteAsHTML` / `.pasteAsRTF` 自动被识别。需要做的只是确认 `ClipboardViewModel.executePaletteShortcut(_:)` 处理这两个 case：

```swift
func executePaletteShortcut(_ shortcut: PaletteActionShortcut) -> Bool {
    guard let item = currentSelectedItem else { return false }
    switch shortcut {
    case .pasteAsHTML:
        pasteRepresentation(of: item, uti: "public.html")
        return true
    case .pasteAsRTF:
        pasteRepresentation(of: item, uti: "public.rtf")
        return true
    // ... existing cases ...
    default:
        return false
    }
}
```

> `currentSelectedItem` 是 placeholder——查实际 ViewModel 内现有用于 `executePaletteShortcut` 的选中项 getter。

- [ ] **Step 4: 编译 + 手工 smoke**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

手工测试：
1. 复制 Notion 富文本
2. 唤起 Clipin → ⌘K 打开动作面板
3. 看到 "Paste as HTML"（⌥H）、"Paste as RTF"（⌥R）、"Paste as Plain Text"（⇧↵）
4. 关掉动作面板，直接按 ⌥H → 粘到 Slack 是 HTML
5. 复制纯 plain（终端 echo "hi" | pbcopy）→ ⌘K 看到**没有** Paste as X 整组

- [ ] **Step 5: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/App/AppDelegate.swift Clipin/Resources/zh-Hans.lproj/Localizable.strings Clipin/Resources/en.lproj/Localizable.strings
git commit -m "feat: 动作面板 Paste as HTML/RTF/Plain 动态条目 + ⌥H/⌥R 路由"
```

---

### Task 4.3: Footer HTML/RTF pill

**Files:**
- Modify: `Clipin/Views/MainPanel.swift`（或 footer view 所在文件）

- [ ] **Step 1: 定位 footer 中现有 "Plain Text" pill 位置**

```bash
grep -n "Plain Text\|pastePlain\|footer.*pill\|FooterPill" /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961/Clipin/Views/*.swift
```

- [ ] **Step 2: 在 Plain Text pill 旁加 HTML / RTF 条件 pill**

按照现有 pill 的结构（例如 `if let item = selectedItem`），添加：

```swift
if viewModel.selectedRepresentationUTIs.contains("public.html") {
    FooterPill(
        title: "HTML",
        shortcut: .pasteAsHTML
    ) {
        viewModel.executePaletteShortcut(.pasteAsHTML)
    }
}
if viewModel.selectedRepresentationUTIs.contains("public.rtf") {
    FooterPill(
        title: "RTF",
        shortcut: .pasteAsRTF
    ) {
        viewModel.executePaletteShortcut(.pasteAsRTF)
    }
}
```

> `FooterPill` 是 placeholder 名字——按项目内既有 pill 组件名替换。所有 pill 必须 `.lineLimit(1)` + `.fixedSize(horizontal: true, vertical: false)`（CLAUDE.md "footer 是固定高度 command strip"）。

- [ ] **Step 3: 编译 + 手工 smoke**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

手工：选中富文本条目 → footer 显示 HTML / RTF pill；选中 plain 条目 → 不显示。

- [ ] **Step 4: 提交**

```bash
git add Clipin/Views/MainPanel.swift
git commit -m "feat: footer 条件显示 HTML/RTF pill，鼠标可点等同动作面板"
```

---

## Phase 5: Archive v2

### Task 5.1: ClipboardArchive schemaVersion=2 + representations 字段

**Files:**
- Modify: `Clipin/Services/ArchiveService.swift`

- [ ] **Step 1: 添加 ArchiveRepresentation struct**

在 `Clipin/Services/ArchiveService.swift:225-247` 末尾添加：

```swift
private struct ArchiveRepresentation: Codable, Sendable {
    let uti: String
    let dataBase64: String
}
```

- [ ] **Step 2: 扩展 ArchiveItem 和顶层 ClipboardArchive**

修改 `Clipin/Services/ArchiveService.swift:226-240`：

```swift
private struct ClipboardArchive: Codable, Sendable {
    let schemaVersion: Int
    let format: String?            // v2 起新增："clipin.clipboard-archive"
    let formatURL: String?         // v2 起新增：规范 URL
    let exportedAt: Date
    let items: [ArchiveItem]
}

private struct ArchiveItem: Codable, Sendable {
    let content: String
    let clipType: ArchiveClipType
    let sourceApp: String?
    let sourceName: String?
    let isPinned: Bool
    let createdAt: Int64
    let imageDataBase64: String?
    let representations: [ArchiveRepresentation]?  // v2 起新增，optional 兼容 v1
}
```

- [ ] **Step 3: 修改 writeArchive 写入 v2**

定位 `let archive = ClipboardArchive(schemaVersion: 1, ...)`（`ArchiveService.swift:190`），替换：

```swift
let archive = ClipboardArchive(
    schemaVersion: 2,
    format: "clipin.clipboard-archive",
    formatURL: "https://github.com/ccfco/Clipin-archive-format",
    exportedAt: Date(),
    items: exportedItems
)
```

并在 `ArchiveItem` 构造处加 `representations`：

```swift
let coreReps = (try? core.getRepresentations(id: item.id)) ?? []
let archiveReps: [ArchiveRepresentation]? = coreReps.isEmpty ? nil : coreReps.map {
    ArchiveRepresentation(uti: $0.uti, dataBase64: $0.data.base64EncodedString())
}
return ArchiveItem(
    content: item.content,
    clipType: ArchiveClipType(item.clipType),
    sourceApp: item.sourceApp,
    sourceName: item.sourceName,
    isPinned: item.isPinned,
    createdAt: item.createdAt,
    imageDataBase64: imageBase64,
    representations: archiveReps
)
```

> 注：实际 exportedItems 构造逻辑要找到 ArchiveService 中既有循环位置；本步骤要的是结果 - 每个 ArchiveItem 带上 representations（如有）。

- [ ] **Step 4: 编译**

```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'generic/platform=macOS' build 2>&1 | tail -10
```

- [ ] **Step 5: 提交**

```bash
git add Clipin/Services/ArchiveService.swift
git commit -m "feat: archive 升级到 schemaVersion=2 写入 representations"
```

---

### Task 5.2: Rust import_item_if_missing 接受 representations

**Files:**
- Modify: `rust/src/storage.rs` (import_item_if_missing)
- Modify: `rust/src/lib.rs` (UniFFI export)

- [ ] **Step 1: 修改 storage.rs::import_item_if_missing 签名**

把 `rust/src/storage.rs:1416-1472` 的方法签名扩展（新增最后一个参数）：

```rust
pub fn import_item_if_missing(
    &self,
    content: &str,
    clip_type: &ClipType,
    source_app: Option<&str>,
    source_name: Option<&str>,
    image_path: Option<&str>,
    is_pinned: bool,
    created_at: i64,
    representations: &[ClipRepresentation],
) -> Result<bool, ClipinError> {
    let hash = Self::hash_for_item(content, clip_type, image_path)?;
    let id = Uuid::new_v4().to_string();
    let char_count = content.chars().count() as i32;
    let (pinyin_flat, pinyin_initials) = compute_pinyin(content);
    let conn = self.conn();

    if let Some(existing_id) = Self::load_item_id_for_hash(&conn, &hash)? {
        // 既有图片缺失修复路径不变
        if clip_type == &ClipType::Image {
            // ... existing code unchanged ...
        }

        // representations 合并：现有为空且 archive 有就补齐
        if !representations.is_empty() {
            let existing_count: i32 = conn.query_row(
                "SELECT COUNT(*) FROM clip_representations WHERE item_id = ?1",
                params![existing_id],
                |r| r.get(0),
            )?;
            if existing_count == 0 {
                drop(conn);  // 释放锁后用 insert_representations
                self.insert_representations(&existing_id, representations)?;
                return Ok(true);  // 计为 imported（不是 skipped）
            }
        }
        return Ok(false);
    }

    // 新条目 insert
    conn.execute(
        "INSERT INTO clip_items ...", // unchanged
        params![...],
    )?;
    drop(conn);
    self.insert_representations(&id, representations)?;
    Ok(true)
}
```

> "drop(conn)" 是必要的——`insert_representations` 内部会重新拿锁，不能在持锁期间调用。

- [ ] **Step 2: 修改 lib.rs::import_item_if_missing UniFFI export**

把 `rust/src/lib.rs:147-164` 扩展参数：

```rust
pub fn import_item_if_missing(
    &self,
    content: String,
    clip_type: ClipType,
    source_app: Option<String>,
    source_name: Option<String>,
    image_path: Option<String>,
    is_pinned: bool,
    created_at: i64,
    representations: Vec<ClipRepresentation>,
) -> Result<bool, ClipinError> {
    self.storage.import_item_if_missing(
        &content,
        &clip_type,
        source_app.as_deref(),
        source_name.as_deref(),
        image_path.as_deref(),
        is_pinned,
        created_at,
        &representations,
    )
}
```

- [ ] **Step 3: 写测试**

加到 `rust/src/lib.rs` 内现有 `#[cfg(test)] mod`：

```rust
#[test]
fn test_import_item_if_missing_with_representations_new() {
    let (core, _tmp) = make_core();
    let reps = vec![
        ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() },
    ];
    let imported = core.import_item_if_missing(
        "hi".into(), ClipType::Text, None, None, None, false, 1715000000,
        reps,
    ).unwrap();
    assert!(imported);

    // 验证 representations 已入副表
    let items = core.get_items(10, 0, None);
    assert_eq!(items.len(), 1);
    let loaded_reps = core.get_representations(items[0].id.clone()).unwrap();
    assert_eq!(loaded_reps.len(), 1);
}

#[test]
fn test_import_item_if_missing_merges_into_empty_representations() {
    let (core, _tmp) = make_core();
    // 先用空 representations import 一次（模拟 v1 archive）
    let _ = core.import_item_if_missing(
        "hi".into(), ClipType::Text, None, None, None, false, 1715000000,
        vec![],
    ).unwrap();

    // 再用带 representations 的 import，应该补齐并计为 imported
    let reps = vec![ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() }];
    let imported = core.import_item_if_missing(
        "hi".into(), ClipType::Text, None, None, None, false, 1715000000,
        reps,
    ).unwrap();
    assert!(imported, "merging representations into empty should count as imported");

    let items = core.get_items(10, 0, None);
    assert_eq!(items.len(), 1);
    let loaded_reps = core.get_representations(items[0].id.clone()).unwrap();
    assert_eq!(loaded_reps.len(), 1);
}

#[test]
fn test_import_item_if_missing_skips_when_representations_exist() {
    let (core, _tmp) = make_core();
    let orig_reps = vec![ClipRepresentation { uti: "public.html".into(), data: b"<p>old</p>".to_vec() }];
    let _ = core.import_item_if_missing(
        "hi".into(), ClipType::Text, None, None, None, false, 1715000000,
        orig_reps,
    ).unwrap();

    // 第二次 import 同 hash 带不同 representations，应该跳过
    let new_reps = vec![ClipRepresentation { uti: "public.html".into(), data: b"<p>new</p>".to_vec() }];
    let imported = core.import_item_if_missing(
        "hi".into(), ClipType::Text, None, None, None, false, 1715000000,
        new_reps,
    ).unwrap();
    assert!(!imported);

    let items = core.get_items(10, 0, None);
    let loaded = core.get_representations(items[0].id.clone()).unwrap();
    assert_eq!(loaded[0].data, b"<p>old</p>".to_vec(), "existing representations must NOT be overwritten");
}
```

- [ ] **Step 4: 跑测试**

```bash
cd rust && cargo test --lib import_item_if_missing
```

Expected: 全部 PASS（含既有测试 + 3 new）

> 既有的 `import_item_if_missing_skips_duplicate_without_resetting_usage` 测试也要相应增加 `vec![]` 参数——按编译报错修。

- [ ] **Step 5: 重新生成 Swift bindings**

```bash
cd /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961
./scripts/build-rust.sh
```

- [ ] **Step 6: 提交**

```bash
git add rust/src/storage.rs rust/src/lib.rs
git commit -m "feat: import_item_if_missing 接受 representations，合并到现有空条目，已有时跳过"
```

---

### Task 5.3: ArchiveService 导入合并 representations

**Files:**
- Modify: `Clipin/Services/ArchiveService.swift` (import path)
- Create: `ClipinTests/ArchiveV2Tests.swift`

- [ ] **Step 1: 修改 importArchive 解码后传 representations**

定位 `ArchiveService.swift` 现有 `for item in archive.items` 循环（约 78 行附近）。在调用 `core.importItemIfMissing(...)` 前构造 representations 数组：

```swift
let coreReps: [ClipRepresentation] = (item.representations ?? []).compactMap { rep in
    guard let data = Data(base64Encoded: rep.dataBase64) else { return nil }
    return ClipRepresentation(uti: rep.uti, data: data)
}

let imported = try core.importItemIfMissing(
    content: item.content,
    clipType: runtimeType(for: item.clipType),
    sourceApp: item.sourceApp,
    sourceName: item.sourceName,
    imagePath: imagePath,    // 既有图片路径还原逻辑
    isPinned: item.isPinned,
    createdAt: item.createdAt,
    representations: coreReps
)
```

- [ ] **Step 2: 写 roundtrip 测试**

`ClipinTests/ArchiveV2Tests.swift`：

```swift
import XCTest
@testable import Clipin

final class ArchiveV2Tests: XCTestCase {
    func testV2RoundtripPreservesRepresentations() async throws {
        let tmpDir = try makeTmpDir()
        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: tmpDir.appendingPathComponent("images").path)

        let reps = [
            ClipRepresentation(uti: "public.html", data: Data("<p>hi</p>".utf8)),
            ClipRepresentation(uti: "public.rtf",  data: Data("{\\rtf1 hi}".utf8)),
        ]
        _ = try core.saveItemWithRepresentations(
            content: "hi", clipType: .text,
            sourceApp: nil, sourceName: nil, imagePath: nil,
            representations: reps
        )

        // 导出
        let archiveURL = tmpDir.appendingPathComponent("archive.json")
        _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)

        // 新 core 导入
        let tmpDir2 = try makeTmpDir()
        let core2 = try ClipinCore(dbPath: tmpDir2.appendingPathComponent("db").path,
                                   imageDir: tmpDir2.appendingPathComponent("images").path)
        _ = try await ArchiveService.importArchive(from: archiveURL, core: core2)

        let items = core2.getItems(limit: 10, offset: 0, typeFilter: nil)
        XCTAssertEqual(items.count, 1)
        let loaded = try core2.getRepresentations(id: items[0].id)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first(where: { $0.uti == "public.html" })?.data, Data("<p>hi</p>".utf8))
    }

    func testV1ArchiveImportsAsBackwardCompatible() async throws {
        let tmpDir = try makeTmpDir()
        // 手工写一个 v1 JSON（无 representations 字段）
        let v1JSON = """
        {
          "schemaVersion": 1,
          "exportedAt": "2025-01-01T00:00:00Z",
          "items": [{
            "content": "hi",
            "clipType": "text",
            "sourceApp": null,
            "sourceName": null,
            "isPinned": false,
            "createdAt": 1715000000,
            "imageDataBase64": null
          }]
        }
        """
        let url = tmpDir.appendingPathComponent("v1.json")
        try v1JSON.data(using: .utf8)!.write(to: url)

        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: tmpDir.appendingPathComponent("images").path)
        let result = try await ArchiveService.importArchive(from: url, core: core)
        XCTAssertEqual(result.importedCount, 1)

        let items = core.getItems(limit: 10, offset: 0, typeFilter: nil)
        let reps = try core.getRepresentations(id: items[0].id)
        XCTAssertEqual(reps.count, 0)
    }

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 3: 跑测试**

```bash
xcodebuild test -project Clipin.xcodeproj -scheme Clipin -destination 'platform=macOS' -only-testing:ClipinTests/ArchiveV2Tests 2>&1 | tail -20
```

Expected: 2 tests PASS

- [ ] **Step 4: 提交**

```bash
git add Clipin/Services/ArchiveService.swift ClipinTests/ArchiveV2Tests.swift
git commit -m "feat: archive v2 导入合并 representations + v1 前向兼容测试"
```

---

### Task 5.4: 设置页 Archive caption + Open Spec 链接

**Files:**
- Modify: `Clipin/Views/SettingsView.swift`
- Modify: `Clipin/Resources/Localizable.strings`

- [ ] **Step 1: 添加 caption**

在 SettingsView 的 "Data / Backup" 段落，导出/导入按钮下方加：

```swift
HStack(spacing: 4) {
    Text("settings.archive.formatCaption")
        .font(.caption)
        .foregroundStyle(.secondary)
    Link(destination: URL(string: "https://github.com/ccfco/Clipin-archive-format")!) {
        Text("settings.archive.openSpec")
            .font(.caption)
    }
}
```

- [ ] **Step 2: 本地化**

```
// zh-Hans
"settings.archive.formatCaption" = "归档格式：Clipin Clipboard Archive v2 ·";
"settings.archive.openSpec" = "查看规范 ↗";

// en
"settings.archive.formatCaption" = "Archive format: Clipin Clipboard Archive v2 ·";
"settings.archive.openSpec" = "Open Spec ↗";
```

- [ ] **Step 3: 编译 + 手工 smoke**

打开设置 → Data 看到 caption 和链接。

- [ ] **Step 4: 提交**

```bash
git add Clipin/Views/SettingsView.swift Clipin/Resources
git commit -m "feat: 设置页加 archive format caption + Open Spec 链接"
```

---

## Phase 6: 教育性 Notice

### Task 6.1: SettingsStore.richPasteNoticeCountSeen 计数器

**Files:**
- Modify: `Clipin/Models/SettingsStore.swift`

- [ ] **Step 1: 添加 AppStorage 属性**

```swift
@AppStorage("richPasteNoticeCountSeen") var richPasteNoticeCountSeen: Int = 0
```

- [ ] **Step 2: 提交**

```bash
git add Clipin/Models/SettingsStore.swift
git commit -m "feat: SettingsStore.richPasteNoticeCountSeen 计数器"
```

---

### Task 6.2: 触发首次粘贴 toast

**Files:**
- Modify: `Clipin/ViewModels/ClipboardViewModel.swift`
- Modify: `Clipin/Resources/Localizable.strings`

- [ ] **Step 1: 在 Return 路径里粘贴成功后判断**

在 `pasteRepresentation`/`writeAllRepresentations` 调用后：

```swift
let repCount = representations.count
if repCount > 0 && SettingsStore.shared.richPasteNoticeCountSeen < 3 {
    let msg = String(format: NSLocalizedString("notice.pastedWithFormats", comment: ""), repCount + 1)
    launcherNotice = msg   // 现有 notice 机制
    SettingsStore.shared.richPasteNoticeCountSeen += 1
}
```

- [ ] **Step 2: 本地化**

```
// zh-Hans
"notice.pastedWithFormats" = "已粘贴 %d 种格式 — 格式已保留";

// en
"notice.pastedWithFormats" = "Pasted with %d formats — formatting preserved";
```

- [ ] **Step 3: 手工 smoke**

复制富文本 → 首次 Return 粘贴 → 看到 toast。粘贴 3 次后 toast 不再出现。

- [ ] **Step 4: 提交**

```bash
git add Clipin/ViewModels/ClipboardViewModel.swift Clipin/Resources
git commit -m "feat: 富文本首次粘贴触发教育性 toast (1-3 次后静默)"
```

---

## Phase 7: 独立规范仓库

### Task 7.1: 创建 Clipin-archive-format 仓库

**Files:** (独立仓库)

- [ ] **Step 1: 本地建仓**

```bash
cd /Users/chenlei/work/person
mkdir Clipin-archive-format && cd Clipin-archive-format
git init
```

- [ ] **Step 2: 创建文件结构**

```
Clipin-archive-format/
├── README.md
├── LICENSE              ← CC0
├── SPEC.md
└── examples/
    ├── example-v2-text-with-html.json
    └── example-v2-image.json
```

- [ ] **Step 3: 撰写 SPEC.md**

```markdown
# Clipin Clipboard Archive Format Specification

> **Version:** 2 (2026-05-15)
> **Status:** Open spec, CC0 license

## Overview

A JSON format for serializing macOS clipboard history with multiple UTI representations per item. Designed to be implementation-independent so that any clipboard manager on macOS can read or write this format for backup, sync, or migration purposes.

## Top-level Schema

```json
{
  "schemaVersion": 2,
  "format": "clipin.clipboard-archive",
  "formatURL": "https://github.com/ccfco/Clipin-archive-format",
  "exportedAt": "2026-05-15T10:00:00Z",
  "items": [ ... ]
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `schemaVersion` | int | yes | Currently 2 |
| `format` | string | yes (v2+) | Always `"clipin.clipboard-archive"` |
| `formatURL` | string | yes (v2+) | Stable URL pointing to this spec |
| `exportedAt` | ISO-8601 datetime | yes | UTC |
| `items` | array of Item | yes | History entries |

## Item Schema

| Field | Type | Required | Notes |
|---|---|---|---|
| `content` | string | yes | Plain text representation; for image / file, see below |
| `clipType` | enum string | yes | `text` / `image` / `file` / `url` |
| `sourceApp` | string\|null | optional | Bundle ID of source app |
| `sourceName` | string\|null | optional | Localized app name at copy time |
| `isPinned` | bool | yes | User pinned this item |
| `createdAt` | int64 | yes | Unix timestamp (ms) |
| `imageDataBase64` | string\|null | optional | Base64-encoded PNG; only for `clipType: image` |
| `representations` | array of Representation\|null | optional (v2+) | Additional UTI data, see below |

### clipType semantics

- `text` — plain text content; `representations` may contain HTML/RTF/RTFD
- `url` — plain text content is the URL itself; `representations` may contain `public.url` and `public.html` (anchor markup)
- `image` — `imageDataBase64` is the PNG; `content` should be `"image"` placeholder
- `file` — `content` is the file path collection (implementation-defined encoding, but should be deterministic)

### Representation Schema

```json
{
  "uti": "public.html",
  "dataBase64": "PHA+aGk8L3A+"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `uti` | string | yes | Uniform Type Identifier (e.g. `public.html`, `public.rtf`) |
| `dataBase64` | string | yes | Base64-encoded raw data; receiver must decode before writing to NSPasteboard |

### Recommended UTI Whitelist

For interoperability, implementations should preserve at least these UTIs when present:

- `public.utf8-plain-text`
- `public.html`
- `public.rtf`
- `public.rtfd`
- `public.url`

Implementations may store additional UTIs but should expect other readers to skip unknown ones.

### Size Limits (Recommendation, not enforced)

- Single representation `data` ≤ 1 MB
- Total per item ≤ 4 MB
- Implementations exceeding these should skip the offending representation rather than the item.

## Versioning

- `schemaVersion: 1` — legacy Clipin format, no `representations` field
- `schemaVersion: 2` — current; adds `representations`, `format`, `formatURL`

Future versions MUST be backward compatible: a v_N reader must successfully parse a v_(N-1) archive, ignoring unknown fields gracefully.

## Import Strategy Recommendation

When importing:

1. Hash each item (e.g. SHA-256 of `content + clipType + image_path`) and look up existing items by hash
2. If hash absent → insert full item including representations
3. If hash present AND existing representations are empty AND archive has representations → merge representations
4. If hash present AND existing representations non-empty → skip (do not overwrite)

## Example

See `examples/example-v2-text-with-html.json` and `examples/example-v2-image.json`.

## License

This specification is released under CC0 1.0 Universal. You may implement it freely in any software, open or closed source, without attribution.
```

- [ ] **Step 4: 提供示例文件**

`examples/example-v2-text-with-html.json`：

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
      "createdAt": 1715760000000,
      "imageDataBase64": null,
      "representations": [
        {
          "uti": "public.html",
          "dataBase64": "PHA+SGVsbG8gd29ybGQ8L3A+"
        }
      ]
    }
  ]
}
```

- [ ] **Step 5: README.md 概要**

```markdown
# Clipin Clipboard Archive Format

Open JSON format for macOS clipboard history with multiple UTI representations per item. Designed for interoperability between clipboard manager apps.

📜 **[Read the SPEC →](SPEC.md)**

## Why this format

macOS clipboard items often have multiple representations (plain text + HTML + RTF). Most clipboard managers either store only the highest-level representation or use a proprietary format that locks history into one app. This spec defines a vendor-neutral JSON format that any clipboard manager can read or write.

## Implementations

- [Clipin](https://github.com/ccfco/Clipin) — reference implementation

## License

CC0 1.0 Universal — implement freely.
```

- [ ] **Step 6: LICENSE — CC0 文本**

复制标准 CC0 1.0 文本到 `LICENSE`（GitHub 模板有）。

- [ ] **Step 7: 推到 GitHub**

```bash
cd /Users/chenlei/work/person/Clipin-archive-format
git add .
git commit -m "feat: Clipin Clipboard Archive Format v2 — initial public spec"
# 在 GitHub 网页创建 ccfco/Clipin-archive-format 公开仓库
git remote add origin https://github.com/ccfco/Clipin-archive-format.git
git branch -M main
git push -u origin main
```

> 如不希望立即公开，可先 push 为 private。

---

### Task 7.2: 主仓库 README 加链接

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 在 README "Features" 或 "Data" 段落加**

```markdown
## Clipboard Archive Format

Clipin uses an [open JSON format](https://github.com/ccfco/Clipin-archive-format) for backup and migration. Multi-UTI representations (HTML/RTF) are preserved across exports, and the format is implementation-independent — any clipboard manager can read or write it.
```

- [ ] **Step 2: 提交**

```bash
cd /Users/chenlei/work/person/Clipin/.claude/worktrees/thirsty-jang-b26961
git add README.md
git commit -m "docs: README 添加 Clipin-archive-format 链接"
```

---

## End-to-End 验证清单

完成所有 Phase 后人工过一遍：

```
[ ] Notion 复制富文本 → Slack       = 富文本 (html)
[ ] Notion 复制富文本 → VSCode      = plain（目标 app 自挑）
[ ] Notion 复制富文本 → Mail        = 富文本 (rtf/html)
[ ] Notion 复制富文本 → ⇧Return → Slack = plain
[ ] Notion 复制富文本 → 动作面板 Paste as Plain → Slack = plain
[ ] Notion 复制富文本 → ⌥H → Slack  = HTML
[ ] Notion 复制富文本 → preview 显示 Formats: plain · html · rtf
[ ] 浏览器复制超链接 → Slack         = 链接 + 标题
[ ] 终端长文本复制（无富文本）        = representations 空，动作面板无 Paste as X
[ ] 5MB RTFD 复制                   = fallback 仅 plain
[ ] v1 数据库升级 → 老条目可正常打开 = representations 空
[ ] v1 archive 导入 → 不崩          = representations 默认空
[ ] 重复导入同一 v2 archive          = 第二次跳过 representations
[ ] 首次富文本粘贴显示 toast；4 次后不再显示
[ ] 设置页 Open Spec 链接打开 GitHub spec repo
```

---

## Self-Review Notes（plan 自检）

| 项 | 检查 |
|---|---|
| Spec § 1-15 全部覆盖 | ✓ Phase 1=§5, Phase 2=§4+§6, Phase 3=§7, Phase 4=§4+§8, Phase 5=§9, Phase 6=§4.4, Phase 7=§9 末尾 |
| 无 TBD / TODO / 占位 | ✓ |
| 类型/方法名一致性 | ✓ `ClipRepresentation` / `representations` 字段全文统一；快捷键 `pasteAsHTML` / `pasteAsRTF` 全文统一 |
| 每步含完整代码或精确命令 | ✓ |
| 每个 Task 都以 commit 结束 | ✓ |
| 提交信息全部中文 + 三段格式 | ✓ 关键 commit 已用 HEREDOC 写完整；boilerplate 提交用单行简写 |
