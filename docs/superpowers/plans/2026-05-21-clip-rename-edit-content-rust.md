# Clipin Rename + Edit Content — Rust 后端实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 `clip_items` 增加 `alias`(用户别名)列,并提供 `set_alias`/`update_content` 两个写接口,让别名进入搜索/列表/备份,让内容可被编辑修订。

**Architecture:** 沿用 Clipin 既有的版本化 migration(每个 `migrate_to_vN` 独立冻结)。`alias` 作为可空列加入 `clip_items`,FTS5 虚拟表重建一次把 `alias` 纳为可搜索列(与 `ocr_text`/`pinyin` 同构)。别名拼音并入既有 `pinyin_flat`/`pinyin_initials` 两列(入参为 `content + alias`),不新增拼音列。

**Tech Stack:** Rust, rusqlite + SQLite FTS5(trigram), UniFFI, `cargo test --lib`。

**关联 spec:** `docs/superpowers/specs/2026-05-21-clip-rename-edit-content-design.md`(单元 1/2/3)

**前置说明:** 本计划是该 feature 的后端部分;前端(Swift)见配套计划 `2026-05-21-clip-rename-edit-content-swift.md`,它依赖本计划产出的 UniFFI binding。

**测试归属约定:**
- Task 1 的 migration 测试加在 `rust/src/storage.rs` 的 `#[cfg(test)] mod migration_tests`(用 `Storage::new` + `storage.conn.lock()`)。
- Task 2-7 的功能测试加在 `rust/src/lib.rs` 的 `#[cfg(test)] mod tests`(用既有的 `setup_core()` / `core.*` API)。

**所有命令在 `rust/` 目录下执行。**

---

### Task 1: Migration v10 — 新增 alias 列 + 重建 FTS5

**Files:**
- Modify: `rust/src/storage.rs`(`run_migrations` 约 114-149;新增 `migrate_to_v10`;`migration_tests` 模块约 1770-1830)

- [ ] **Step 1: 写失败测试**

在 `rust/src/storage.rs` 的 `mod migration_tests` 内(`test_v9_creates_representations_table` 之后)新增:

```rust
    #[test]
    fn test_v10_adds_alias_column_and_rebuilds_fts() {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
        let img_dir = tmp.path().join("images").to_string_lossy().to_string();
        std::fs::create_dir_all(&img_dir).unwrap();

        let storage = Storage::new(&db_path, &img_dir).unwrap();
        assert_eq!(storage.schema_version(), 10);

        let conn = storage.conn.lock().unwrap();

        // clip_items 应有 alias 列
        let has_alias: bool = conn
            .prepare("PRAGMA table_info(clip_items)")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(1))
            .unwrap()
            .any(|name| name.as_deref() == Ok("alias"));
        assert!(has_alias, "clip_items 应有 alias 列");

        // clip_fts 应索引 alias 列
        let fts_sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='table' AND name='clip_fts'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(fts_sql.contains("alias"), "clip_fts 应含 alias 列");

        // clip_items_au 触发器的 UPDATE OF 列集应包含 alias
        let trigger_sql: String = conn
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='clip_items_au'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(
            trigger_sql.contains(
                "AFTER UPDATE OF content, source_name, ocr_text, alias, pinyin_flat, pinyin_initials"
            ),
            "clip_items_au 应在 UPDATE OF 列集里包含 alias"
        );
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_v10_adds_alias_column_and_rebuilds_fts`
Expected: FAIL — `assert_eq!(storage.schema_version(), 10)` 失败(当前为 9)。

- [ ] **Step 3: 新增 `migrate_to_v10` 函数**

在 `rust/src/storage.rs` 的 `migrate_to_v9` 函数之后新增:

```rust
    fn migrate_to_v10(conn: &Connection) -> Result<(), ClipinError> {
        // 用户别名列。可空：NULL 表示未命名，列表回退到内容兜底预览。
        // 幂等检查：崩溃重启重跑时不能重复 ALTER。
        let has_alias: bool = conn
            .prepare("PRAGMA table_info(clip_items)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .any(|n| n.as_deref() == Ok("alias"));
        if !has_alias {
            conn.execute_batch("ALTER TABLE clip_items ADD COLUMN alias TEXT;")?;
        }

        // 重建 FTS5：把 alias 纳为可搜索列，与 content/ocr_text/pinyin 同构。
        // clip_items_au 沿用 v8 的收窄写法（AFTER UPDATE OF ...），列集追加 alias，
        // 使 set_alias 的别名变更能驱动 FTS 同步，而 paste_count/created_at 仍不重写 FTS。
        conn.execute_batch(
            "DROP TRIGGER IF EXISTS clip_items_ai;
             DROP TRIGGER IF EXISTS clip_items_ad;
             DROP TRIGGER IF EXISTS clip_items_au;
             DROP TABLE   IF EXISTS clip_fts;

             CREATE VIRTUAL TABLE clip_fts USING fts5(
                 content, source_name, ocr_text, alias, pinyin_flat, pinyin_initials,
                 content='clip_items', content_rowid='rowid', tokenize='trigram'
             );

             CREATE TRIGGER clip_items_ai AFTER INSERT ON clip_items BEGIN
                 INSERT INTO clip_fts(rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials)
                 VALUES(new.rowid,new.content,new.source_name,new.ocr_text,new.alias,new.pinyin_flat,new.pinyin_initials);
             END;

             CREATE TRIGGER clip_items_ad AFTER DELETE ON clip_items BEGIN
                 INSERT INTO clip_fts(clip_fts,rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials)
                 VALUES('delete',old.rowid,old.content,old.source_name,old.ocr_text,old.alias,old.pinyin_flat,old.pinyin_initials);
             END;

             CREATE TRIGGER clip_items_au
             AFTER UPDATE OF content, source_name, ocr_text, alias, pinyin_flat, pinyin_initials
             ON clip_items BEGIN
                 INSERT INTO clip_fts(clip_fts,rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials)
                 VALUES('delete',old.rowid,old.content,old.source_name,old.ocr_text,old.alias,old.pinyin_flat,old.pinyin_initials);
                 INSERT INTO clip_fts(rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials)
                 VALUES(new.rowid,new.content,new.source_name,new.ocr_text,new.alias,new.pinyin_flat,new.pinyin_initials);
             END;

             INSERT INTO clip_fts(rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials)
             SELECT rowid,content,source_name,ocr_text,alias,pinyin_flat,pinyin_initials FROM clip_items;

             PRAGMA user_version = 10;",
        )?;
        Ok(())
    }
```

- [ ] **Step 4: 在 `run_migrations` 接入 v10 分支**

在 `run_migrations` 函数里,`if from_version < 9 { ... }` 块之后、`Ok(())` 之前插入:

```rust
        if from_version < 10 {
            Self::migrate_to_v10(&self.conn())?;
        }
```

- [ ] **Step 5: 更新现有 migration 测试的版本号断言**

`migration_tests` 模块内有三处硬编码 `9`,全部改为 `10`:

- `test_fresh_db_is_version_1`: `assert_eq!(storage.schema_version(), 9, "新建数据库应为 v9");` → `assert_eq!(storage.schema_version(), 10, "新建数据库应为 v10");`
- `test_existing_v0_migrates_to_v1`: `assert_eq!(storage.schema_version(), 9, "旧数据库应 migrate 到 v9");` → `assert_eq!(storage.schema_version(), 10, "旧数据库应 migrate 到 v10");`
- `test_migration_is_idempotent`: `assert_eq!(s2.schema_version(), 9);` → `assert_eq!(s2.schema_version(), 10);`

- [ ] **Step 6: 运行 migration 测试确认通过**

Run: `cd rust && cargo test --lib migration_tests`
Expected: PASS — 全部 migration 测试通过,含新增的 `test_v10_adds_alias_column_and_rebuilds_fts`。

- [ ] **Step 7: 提交**

```bash
git add rust/src/storage.rs
git commit -m "$(cat <<'EOF'
feat: DB migration v10 — clip_items 新增 alias 列并重建 FTS5

【根因/背景】支持给粘贴项起用户别名，别名需与 content 等权进入搜索
【改动范围】storage.rs 新增 migrate_to_v10、run_migrations 加 v10 分支、migration 测试版本号断言 9→10
EOF
)"
```

---

### Task 2: `ClipItem` 增加 alias 字段

**Files:**
- Modify: `rust/src/models.rs`(`ClipItem` 结构体 31-48)
- Modify: `rust/src/storage.rs`(所有 `clip_items` 完整行 SELECT、`row_to_item`、`save_item`/`import_item` 的返回结构体)

`alias` 一律加在 `ClipItem` 字段末尾、SELECT 列末尾(FTS JOIN 的 SELECT 里加在 `paste_count` 之后、`clip_fts.rank` 之前),使既有列的 row index 不变。

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_new_item_has_no_alias() {
        let core = setup_core();
        let item = core
            .save_item("plain".into(), ClipType::Text, None, None, None)
            .unwrap();
        assert_eq!(item.alias, None, "新建条目别名应为 None");

        let fetched = core.get_item(item.id.clone()).unwrap();
        assert_eq!(fetched.alias, None, "get_item 读出的别名应为 None");
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_new_item_has_no_alias`
Expected: FAIL — 编译错误,`ClipItem` 无 `alias` 字段。

- [ ] **Step 3: `models.rs` 给 `ClipItem` 加字段**

在 `ClipItem` 结构体 `paste_count` 字段之后追加:

```rust
    /// 用户自定义别名（显示名）。None 表示未命名，列表回退到内容兜底预览。
    pub alias: Option<String>,
```

- [ ] **Step 4: `storage.rs` — `row_to_item` 读取 alias**

`row_to_item` 当前读取 index 0-12。在 `paste_count: row.get(12).unwrap_or(0),` 之后追加一行,使函数体为:

```rust
    fn row_to_item(row: &rusqlite::Row) -> rusqlite::Result<ClipItem> {
        let clip_type_str: String = row.get(2)?;
        Ok(ClipItem {
            id: row.get(0)?,
            content: row.get(1)?,
            clip_type: ClipType::from_str(&clip_type_str),
            source_app: row.get(3)?,
            source_name: row.get(4)?,
            is_pinned: row.get(5)?,
            created_at: row.get(6)?,
            image_path: row.get(7)?,
            char_count: row.get(8)?,
            copy_count: row.get(9)?,
            first_copied_at: row.get(10)?,
            ocr_text: row.get(11)?,
            paste_count: row.get(12).unwrap_or(0),
            alias: row.get(13)?,
        })
    }
```

`row_to_item_search_hit` 的 `raw_rank` 从 index 13 改为 14:

```rust
    fn row_to_item_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipItem>> {
        Ok(SearchHit {
            item: Self::row_to_item(row)?,
            raw_rank: row.get(14)?,
        })
    }
```

- [ ] **Step 5: `storage.rs` — 所有完整行 item SELECT 末尾加 alias 列**

下列 SELECT 的列清单都以 `paste_count` 结尾。对**非 JOIN** 的查询,把 `paste_count` 改为 `paste_count, alias`;对 **FTS JOIN** 的查询,在 `ci.paste_count,` 之后、`clip_fts.rank` 之前插入 `ci.alias,`,即 `... ci.paste_count, ci.alias, clip_fts.rank`。

非 JOIN(列尾 `paste_count` → `paste_count, alias`),共 9 处:
- `get_items` 两处 SQL(type filter 分支与 no filter 分支)
- `export_archive_snapshot` 的 items SELECT
- `get_item` 的 SELECT
- `get_unprocessed_images` 的 SELECT
- `query_raw_item_hits` 的 `else` 分支(LIKE 路径)两处 SQL
- `query_pinyin_item_hits` 的 `else` 分支(LIKE 路径)两处 SQL

FTS JOIN(`ci.paste_count,` 后插 `ci.alias,`),共 4 处:
- `query_raw_item_hits` 的 `if` 分支(FTS 路径)两处 SQL
- `query_pinyin_item_hits` 的 `if` 分支(FTS 路径)两处 SQL

例如 `get_item` 的 SELECT 改为:

```rust
        conn.query_row(
            "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count, alias
             FROM clip_items
             WHERE id = ?1",
            params![id],
            Self::row_to_item,
        )
```

例如 `query_raw_item_hits` 的 FTS 路径(no filter)SELECT 改为:

```sql
SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
       ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count, ci.alias,
       clip_fts.rank
FROM clip_items ci
JOIN clip_fts ON clip_fts.rowid = ci.rowid
WHERE clip_fts MATCH ?1
ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
LIMIT 200
```

- [ ] **Step 6: `storage.rs` — `save_item` 与 `import_item` 的返回结构体加 `alias: None`**

`save_item_with_representations` 函数末尾构造 `ClipItem { ... }` 时,在 `paste_count: preserved.paste_count,` 之后加 `alias: None,`(新建条目无别名)。

`import_item` 函数末尾构造 `ClipItem { ... }` 时,在 `paste_count: 0,` 之后加 `alias: None,`。

- [ ] **Step 7: 运行全部 Rust 测试**

Run: `cd rust && cargo test --lib`
Expected: PASS — 全部测试通过(含新增 `test_new_item_has_no_alias`);无编译错误。

- [ ] **Step 8: 提交**

```bash
git add rust/src/models.rs rust/src/storage.rs
git commit -m "$(cat <<'EOF'
feat: ClipItem 增加 alias 字段并接入全部 item 查询

【根因/背景】别名需随完整记录读出，供 Swift 端渲染与导出
【踩坑记录】alias 一律加在 SELECT 列末尾，保持既有列 row index 不变；FTS JOIN 路径 alias 插在 paste_count 与 clip_fts.rank 之间，rank index 13→14
【改动范围】models.rs ClipItem 加字段；storage.rs 全部 item SELECT、row_to_item、save_item/import_item 返回值
EOF
)"
```

---

### Task 3: `set_alias` — 写入别名并重算拼音

**Files:**
- Modify: `rust/src/storage.rs`(新增 `set_alias` 方法)
- Modify: `rust/src/lib.rs`(新增 UniFFI 导出 `set_alias`)

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_set_alias_writes_and_clears() {
        let core = setup_core();
        let item = core
            .save_item("body".into(), ClipType::Text, None, None, None)
            .unwrap();

        core.set_alias(item.id.clone(), Some("My Label".into())).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias.as_deref(), Some("My Label"));

        // 空字符串归一化为 NULL
        core.set_alias(item.id.clone(), Some("".into())).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias, None);

        // None 同样清空
        core.set_alias(item.id.clone(), Some("X".into())).unwrap();
        core.set_alias(item.id.clone(), None).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias, None);
    }

    #[test]
    fn test_set_alias_chinese_is_searchable_by_pinyin() {
        let core = setup_core();
        let item = core
            .save_item("ghp_xxx".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("密钥".into())).unwrap();

        // 别名拼音全拼命中
        assert_eq!(core.search("miyao".into(), None).unwrap().len(), 1);
        // 别名拼音首字母命中
        assert_eq!(core.search("my".into(), None).unwrap().len(), 1);
    }

    #[test]
    fn test_set_alias_not_found() {
        let core = setup_core();
        let err = core.set_alias("no-such-id".into(), Some("X".into()));
        assert!(matches!(err, Err(ClipinError::NotFound { .. })));
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_set_alias`
Expected: FAIL — 编译错误,`set_alias` 未定义。

- [ ] **Step 3: `storage.rs` 实现 `set_alias`**

在 `update_ocr_text` 方法之后新增。空字符串归一化为 `None`;写别名后重算拼音(入参 `content + " " + alias`),`alias`/`pinyin_flat`/`pinyin_initials` 都在 v10 触发器列集内,FTS 自动同步。

```rust
    /// 写入或清空条目别名。空字符串与 None 都归一化为 SQL NULL。
    /// 别名变更后重算拼音（入参 content + alias），使中文别名可被拼音搜索命中。
    pub fn set_alias(&self, id: &str, alias: Option<&str>) -> Result<(), ClipinError> {
        let normalized: Option<&str> = match alias {
            Some(s) if !s.is_empty() => Some(s),
            _ => None,
        };
        let conn = self.conn();
        let content: String = conn
            .query_row(
                "SELECT content FROM clip_items WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .map_err(|_| ClipinError::NotFound { id: id.to_string() })?;
        let pinyin_source = match normalized {
            Some(a) => format!("{content} {a}"),
            None => content,
        };
        let (pinyin_flat, pinyin_initials) = compute_pinyin(&pinyin_source);
        conn.execute(
            "UPDATE clip_items SET alias = ?1, pinyin_flat = ?2, pinyin_initials = ?3 WHERE id = ?4",
            params![normalized, pinyin_flat, pinyin_initials, id],
        )?;
        Ok(())
    }
```

- [ ] **Step 4: `lib.rs` 新增 UniFFI 导出**

在 `#[uniffi::export] impl ClipinCore` 内,`update_ocr_text` 方法之后新增:

```rust
    /// 写入或清空条目别名（空字符串视为清空）
    pub fn set_alias(&self, id: String, alias: Option<String>) -> Result<(), ClipinError> {
        self.storage.set_alias(&id, alias.as_deref())
    }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd rust && cargo test --lib test_set_alias`
Expected: PASS — `test_set_alias_writes_and_clears`、`test_set_alias_not_found`、`test_set_alias_chinese_is_searchable_by_pinyin` 全部通过(拼音命中由并入 `pinyin_flat`/`pinyin_initials` 实现)。

- [ ] **Step 6: 提交**

```bash
git add rust/src/storage.rs rust/src/lib.rs
git commit -m "$(cat <<'EOF'
feat: 新增 set_alias —— 写入/清空粘贴项别名

【根因/背景】Rename 功能需要把用户输入的别名落库
【踩坑记录】别名变更须重算 pinyin（入参 content+alias），否则中文别名搜不到；空字符串归一化为 NULL
【改动范围】storage.rs 新增 set_alias；lib.rs 新增 UniFFI 导出
EOF
)"
```

---

### Task 4: 别名进入搜索路径

**Files:**
- Modify: `rust/src/storage.rs`(`build_search_query` 的 FTS 列集;`query_raw_item_hits` / `query_raw_list_hits` 的 LIKE 路径)

FTS 路径:`build_search_query` 给 `raw_fts` 的列集加 `"alias"`。LIKE 路径(查询 <3 字):`content LIKE ?1 OR ocr_text LIKE ?1` 加 `OR alias LIKE ?1`。`alias` 为 NULL 时 `NULL LIKE x` 结果为 NULL(假),不会误命中。本 task 只改 `WHERE` 子句,不动任何 SELECT 列。

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_search_matches_alias_text() {
        let core = setup_core();
        let item = core
            .save_item("ghp_abcdefghABCDEF".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("GitHub PAT".into())).unwrap();

        // 长查询走 FTS 路径
        assert_eq!(core.search("GitHub".into(), None).unwrap().len(), 1);
        assert_eq!(core.search_list_items("GitHub".into(), None).unwrap().len(), 1);
        // 短查询走 LIKE 路径
        assert_eq!(core.search("PA".into(), None).unwrap().len(), 1);
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_search_matches_alias_text`
Expected: FAIL — 别名未进搜索列,查 "GitHub"/"PA" 返回 0 条。

- [ ] **Step 3: FTS 列集加 alias**

`build_search_query` 里 `raw_fts` 的列集 `&["content", "source_name", "ocr_text"]` 改为:

```rust
            raw_fts: Self::build_fts5_query_for_columns(
                &raw,
                &["content", "source_name", "ocr_text", "alias"],
            ),
```

- [ ] **Step 4: LIKE 路径加 alias 条件**

`query_raw_item_hits` 的 `else`(LIKE)分支两条 SQL,`WHERE` 子句加 `alias`:
- type filter 版:`WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\')` → `WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\')`
- no filter 版:`WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\'` → `WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\'`

`query_raw_list_hits` 的 `else`(LIKE)分支两条 SQL 同样处理(列名无 `ci.` 前缀,与上面写法一致)。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd rust && cargo test --lib`
Expected: PASS — 全部测试通过,含 `test_search_matches_alias_text`。

- [ ] **Step 6: 提交**

```bash
git add rust/src/storage.rs
git commit -m "$(cat <<'EOF'
feat: 别名进入搜索 —— FTS5 与 LIKE 路径均覆盖 alias

【根因/背景】用户给条目起名后，应能用别名搜到它
【改动范围】storage.rs build_search_query FTS 列集加 alias；query_raw_item_hits / query_raw_list_hits 的 LIKE 路径 WHERE 加 alias 条件
EOF
)"
```

---

### Task 5: `ClipListItem` 增加 alias 字段 + 列表显示名优先别名

**Files:**
- Modify: `rust/src/models.rs`(`ClipListItem` 结构体 51-64)
- Modify: `rust/src/storage.rs`(所有 list SELECT、`row_to_list_item`)

列表显示名(`preview`)的兜底优先级从 `COALESCE(NULLIF(ocr_text,''),content)` 改为 `COALESCE(NULLIF(alias,''),NULLIF(ocr_text,''),content)`。`ClipListItem` 额外携带 `alias`,供 Swift 端判定是否画"有别名"视觉信号。

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_list_item_carries_alias_and_prefers_it_as_preview() {
        let core = setup_core();
        let item = core
            .save_item("ghp_secret_token_value".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 未命名：list item alias 为 None，preview 为内容兜底
        let before = core.get_list_items(10, 0, None).unwrap();
        assert_eq!(before[0].alias, None);
        assert_eq!(before[0].preview, "ghp_secret_token_value");

        // 命名后：list item alias 有值，preview 优先别名
        core.set_alias(item.id.clone(), Some("GitHub PAT".into())).unwrap();
        let after = core.get_list_items(10, 0, None).unwrap();
        assert_eq!(after[0].alias.as_deref(), Some("GitHub PAT"));
        assert_eq!(after[0].preview, "GitHub PAT");
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_list_item_carries_alias_and_prefers_it_as_preview`
Expected: FAIL — 编译错误,`ClipListItem` 无 `alias` 字段。

- [ ] **Step 3: `models.rs` 给 `ClipListItem` 加字段**

在 `ClipListItem` 结构体 `copy_count` 字段之后追加:

```rust
    /// 用户自定义别名。None 表示未命名；非 None 时列表行画"有别名"视觉信号。
    pub alias: Option<String>,
```

- [ ] **Step 4: `storage.rs` — `row_to_list_item` 读取 alias**

`row_to_list_item` 当前读 index 0-10。在 `copy_count: row.get(10).unwrap_or(1),` 之后追加 `alias: row.get(11)?,`:

```rust
    fn row_to_list_item(row: &rusqlite::Row) -> rusqlite::Result<ClipListItem> {
        let clip_type_str: String = row.get(2)?;
        Ok(ClipListItem {
            id: row.get(0)?,
            preview: row.get(1)?,
            clip_type: ClipType::from_str(&clip_type_str),
            source_app: row.get(3)?,
            source_name: row.get(4)?,
            is_pinned: row.get(5)?,
            created_at: row.get(6)?,
            image_path: row.get(7)?,
            char_count: row.get(8)?,
            paste_count: row.get(9).unwrap_or(0),
            copy_count: row.get(10).unwrap_or(1),
            alias: row.get(11)?,
        })
    }
```

`row_to_list_search_hit` 的 `raw_rank` 从 index 11 改为 12:

```rust
    fn row_to_list_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            raw_rank: row.get(12)?,
        })
    }
```

- [ ] **Step 5: `storage.rs` — 所有 list SELECT 改兜底表达式并加 alias 列**

所有 list SELECT 的第二列当前是 `substr(COALESCE(NULLIF(ocr_text,''),content),1,{p})`(JOIN 路径带 `ci.` 前缀)。两处统一改动:

1. 兜底表达式加 alias 优先:`COALESCE(NULLIF(ocr_text,''),content)` → `COALESCE(NULLIF(alias,''),NULLIF(ocr_text,''),content)`(JOIN 路径为 `COALESCE(NULLIF(ci.alias,''),NULLIF(ci.ocr_text,''),ci.content)`)。
2. 列清单末尾加 alias 列:非 JOIN 把末列 `copy_count` 改为 `copy_count, alias`;FTS JOIN 在 `ci.copy_count,` 之后、`clip_fts.rank` 之前插入 `ci.alias,`。

涉及的函数(每个内有 type/pinned 组合的多条 SQL,全部按上面两点改),共 12 处:
- `get_list_items_with_pinned_filter` — 4 个 match 分支各 1 条 SQL(非 JOIN)
- `query_raw_list_hits` — `if`(FTS)分支 2 条、`else`(LIKE)分支 2 条
- `query_pinyin_list_hits` — `if`(FTS)分支 2 条、`else`(LIKE)分支 2 条

非 JOIN 改后样例(`get_list_items_with_pinned_filter` 的 `(None, None)` 分支):

```rust
                let sql = format!(
                    "SELECT id, substr(COALESCE(NULLIF(alias,''),NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count, alias
                     FROM clip_items
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?1 OFFSET ?2",
                    p = Self::LIST_PREVIEW_CHARS
                );
```

FTS JOIN 改后样例(`query_raw_list_hits` 的 FTS no-filter 分支):

```rust
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.alias,''),NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count, ci.alias,
                            clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
```

- [ ] **Step 6: 运行全部 Rust 测试**

Run: `cd rust && cargo test --lib`
Expected: PASS — 全部测试通过,含 `test_list_item_carries_alias_and_prefers_it_as_preview`。

- [ ] **Step 7: 提交**

```bash
git add rust/src/models.rs rust/src/storage.rs
git commit -m "$(cat <<'EOF'
feat: ClipListItem 增加 alias 字段，列表显示名优先别名

【根因/背景】列表行有别名时只显示别名，无别名回退内容兜底
【踩坑记录】preview 兜底优先级 alias→ocr_text→content；alias 列加在 SELECT 末尾，list search hit 的 rank index 11→12
【改动范围】models.rs ClipListItem 加字段；storage.rs 全部 list SELECT、row_to_list_item
EOF
)"
```

---

### Task 6: `update_content` — 编辑真实内容

**Files:**
- Modify: `rust/src/storage.rs`(新增 `update_content` 方法)
- Modify: `rust/src/lib.rs`(新增 UniFFI 导出 `update_content`)

编辑 `content` 会让若干派生数据失效,须在一个事务内一并处理:重算 `content_hash`(`hash` 列)、`char_count`、`pinyin`(入参 `content + alias`),更新 `clip_type`,并清空该条目的 `clip_representations` 副表。不触碰 `created_at`/`copy_count`/`paste_count`/`is_pinned`/`source_app`/`source_name`。不套用去重(即使新 hash 与他条目相同也不合并)。

> 注:`ClipItem` 在 Rust 层没有 `word_count` 列(只有 `char_count`);spec 提到的 word_count 由 Swift 端 `PreviewPane` 在渲染时计算,content 一变自然为新值,Rust 层无需处理。

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_update_content_rewrites_derived_fields() {
        let core = setup_core();
        let item = core
            .save_item("old text".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.increment_paste_count(item.id.clone()).unwrap();

        core.update_content(item.id.clone(), "https://anthropic.com".into(), ClipType::Url)
            .unwrap();

        let updated = core.get_item(item.id.clone()).unwrap();
        assert_eq!(updated.content, "https://anthropic.com");
        assert_eq!(updated.clip_type, ClipType::Url);
        assert_eq!(updated.char_count, 21);
        // 使用信号与身份不变
        assert_eq!(updated.paste_count, 1);
        assert_eq!(updated.created_at, item.created_at);
        assert_eq!(updated.copy_count, item.copy_count);
    }

    #[test]
    fn test_update_content_clears_representations() {
        let core = setup_core();
        let reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>old</p>".to_vec(),
        }];
        let item = core
            .save_item_with_representations(
                "old".into(), ClipType::Text, None, None, None, reps,
            )
            .unwrap();
        assert_eq!(core.get_representations(item.id.clone()).unwrap().len(), 1);

        core.update_content(item.id.clone(), "new".into(), ClipType::Text)
            .unwrap();
        assert_eq!(
            core.get_representations(item.id.clone()).unwrap().len(),
            0,
            "编辑内容后旧富文本表示应被清空"
        );
    }

    #[test]
    fn test_update_content_allows_duplicate_hash() {
        let core = setup_core();
        core.save_item("twin".into(), ClipType::Text, None, None, None)
            .unwrap();
        let other = core
            .save_item("unique".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 把 other 编辑成与第一条相同的内容：不报错、不合并，库中仍是两条
        core.update_content(other.id.clone(), "twin".into(), ClipType::Text)
            .unwrap();
        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 2, "用户主动编辑产生的重复内容不去重");
    }

    #[test]
    fn test_update_content_not_found() {
        let core = setup_core();
        let err = core.update_content("no-such-id".into(), "x".into(), ClipType::Text);
        assert!(matches!(err, Err(ClipinError::NotFound { .. })));
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_update_content`
Expected: FAIL — 编译错误,`update_content` 未定义。

- [ ] **Step 3: `storage.rs` 实现 `update_content`**

在 `set_alias` 方法之后新增。`Self::content_hash` 是私有关联函数(`Sha256(type:content)`),`compute_pinyin` 是模块级函数。

```rust
    /// 编辑条目的真实内容。重算 hash/char_count/pinyin、更新 clip_type、清空副表 representations。
    /// 不触碰 created_at/copy_count/paste_count/is_pinned/source_*。
    /// 不去重：用户主动编辑产生的重复内容是用户意图，保留为多条。
    pub fn update_content(
        &self,
        id: &str,
        new_content: &str,
        new_type: &ClipType,
    ) -> Result<(), ClipinError> {
        let hash = Self::content_hash(new_content, new_type);
        let char_count = new_content.chars().count() as i32;
        let mut conn = self.conn();

        // 别名参与拼音计算：content 变了，pinyin = content + alias。
        let alias: Option<String> = conn
            .query_row(
                "SELECT alias FROM clip_items WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .map_err(|_| ClipinError::NotFound { id: id.to_string() })?;
        let pinyin_source = match alias.as_deref() {
            Some(a) if !a.is_empty() => format!("{new_content} {a}"),
            _ => new_content.to_string(),
        };
        let (pinyin_flat, pinyin_initials) = compute_pinyin(&pinyin_source);

        let tx = conn.transaction()?;
        let affected = tx.execute(
            "UPDATE clip_items
             SET content = ?1, clip_type = ?2, hash = ?3, char_count = ?4,
                 pinyin_flat = ?5, pinyin_initials = ?6
             WHERE id = ?7",
            params![
                new_content,
                new_type.as_str(),
                hash,
                char_count,
                pinyin_flat,
                pinyin_initials,
                id,
            ],
        )?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        tx.execute(
            "DELETE FROM clip_representations WHERE item_id = ?1",
            params![id],
        )?;
        tx.commit()?;
        Ok(())
    }
```

- [ ] **Step 4: `lib.rs` 新增 UniFFI 导出**

在 `#[uniffi::export] impl ClipinCore` 内,`set_alias` 方法之后新增:

```rust
    /// 编辑条目真实内容（仅 text/url；类型由调用方依据新内容判定后传入）
    pub fn update_content(
        &self,
        id: String,
        new_content: String,
        new_type: ClipType,
    ) -> Result<(), ClipinError> {
        self.storage.update_content(&id, &new_content, &new_type)
    }
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd rust && cargo test --lib`
Expected: PASS — 全部测试通过,含 4 个 `test_update_content_*`。

- [ ] **Step 6: 提交**

```bash
git add rust/src/storage.rs rust/src/lib.rs
git commit -m "$(cat <<'EOF'
feat: 新增 update_content —— 编辑粘贴项真实内容

【根因/背景】Edit Content 功能需要修订历史条目的真实内容
【踩坑记录】content 变更须在同一事务内连带失效 hash/char_count/pinyin 并清空副表 representations；不套用去重，用户主动编辑的重复内容保留为多条
【改动范围】storage.rs 新增 update_content；lib.rs 新增 UniFFI 导出
EOF
)"
```

---

### Task 7: 别名进入导入/导出备份

**Files:**
- Modify: `rust/src/storage.rs`(`import_item` / `import_item_if_missing` 增加 alias 参数与 INSERT 列)
- Modify: `rust/src/lib.rs`(两个导出方法的签名同步;`mod tests` 内既有调用点补参数)

导出已由 Task 2 完成 —— `export_archive_snapshot` 的 items SELECT 已含 `alias` 列,`ArchiveSnapshotItem.item` 即带别名。本 task 处理导入:`import_item`/`import_item_if_missing` 增加 `alias` 入参并写入 INSERT。`import_item_if_missing` 命中同 hash 时,若现有条目 `alias` 为空、备份里 `alias` 非空,补上别名并计为 imported。

- [ ] **Step 1: 写失败测试**

在 `rust/src/lib.rs` 的 `mod tests` 内新增:

```rust
    #[test]
    fn test_export_import_roundtrip_preserves_alias() {
        let core = setup_core();
        let item = core
            .save_item("payload".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("Saved Label".into())).unwrap();

        let snapshot = core.export_archive_snapshot().unwrap();
        assert_eq!(snapshot[0].item.alias.as_deref(), Some("Saved Label"));

        // 导入到一个新库
        let fresh = setup_core();
        let imported = fresh
            .import_item_if_missing(
                "payload".into(), ClipType::Text, None, None, None,
                false, 1_000, Some("Saved Label".into()), vec![],
            )
            .unwrap();
        assert!(imported);
        let items = fresh.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias.as_deref(), Some("Saved Label"));
    }

    #[test]
    fn test_import_if_missing_fills_empty_alias() {
        let core = setup_core();
        // 现有条目无别名
        core.save_item("doc".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 同 hash 导入，备份带别名 → 补上并计为 imported
        let imported = core
            .import_item_if_missing(
                "doc".into(), ClipType::Text, None, None, None,
                false, 2_000, Some("Backup Name".into()), vec![],
            )
            .unwrap();
        assert!(imported, "现有别名为空、备份有别名应计为 imported");

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].alias.as_deref(), Some("Backup Name"));
    }

    #[test]
    fn test_import_if_missing_keeps_existing_alias() {
        let core = setup_core();
        let item = core
            .save_item("doc".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("User Edited".into())).unwrap();

        // 同 hash 导入，备份别名不同 → 不覆盖用户已改的别名
        core.import_item_if_missing(
            "doc".into(), ClipType::Text, None, None, None,
            false, 3_000, Some("Backup Name".into()), vec![],
        )
        .unwrap();

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias.as_deref(), Some("User Edited"), "不覆盖用户已有别名");
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd rust && cargo test --lib test_import_if_missing test_export_import_roundtrip`
Expected: FAIL — 编译错误,`import_item_if_missing` 参数数量不匹配(缺 `alias`)。

- [ ] **Step 3: `storage.rs` — `import_item` 增加 alias 参数**

`import_item` 函数签名在 `created_at: i64,` 之后加 `alias: Option<&str>,`。INSERT 语句的列清单加 `alias`、值占位符相应增加。当前 INSERT 为:

```rust
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,?7,?11,?12)",
            params![
                id, content, clip_type.as_str(), source_app, source_name,
                is_pinned as i32, created_at, image_path, char_count, hash,
                pinyin_flat, pinyin_initials,
            ],
        )?;
```

改为(末列加 `alias`,占位符 `?13`):

```rust
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials,alias)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,?7,?11,?12,?13)",
            params![
                id, content, clip_type.as_str(), source_app, source_name,
                is_pinned as i32, created_at, image_path, char_count, hash,
                pinyin_flat, pinyin_initials, alias,
            ],
        )?;
```

`import_item` 末尾构造的 `ClipItem { ... }`,把 Task 2 加的 `alias: None,` 改为 `alias: alias.map(String::from),`。

- [ ] **Step 4: `storage.rs` — `import_item_if_missing` 增加 alias 参数与补全逻辑**

函数签名在 `created_at: i64,` 之后、`representations: &[ClipRepresentation],` 之前加 `alias: Option<&str>,`。

新建分支的 INSERT(`if let Some(existing_id)` 命中分支**之后**那段)按 Step 3 同样方式加 `alias` 列、`?13` 占位符、`params!` 末尾加 `alias`。

在 `if let Some(existing_id) = ...` 命中分支内,representations 补全逻辑(`if !representations.is_empty()` 块)**之前**插入别名补全逻辑:

```rust
            // 现有条目 alias 为空、备份带别名时补上，计为 imported。
            if let Some(new_alias) = alias.filter(|a| !a.is_empty()) {
                let existing_alias: Option<String> = conn.query_row(
                    "SELECT alias FROM clip_items WHERE id = ?1",
                    params![existing_id],
                    |r| r.get(0),
                )?;
                if existing_alias.as_deref().unwrap_or("").is_empty() {
                    conn.execute(
                        "UPDATE clip_items SET alias = ?1 WHERE id = ?2",
                        params![new_alias, existing_id],
                    )?;
                    return Ok(true);
                }
            }
```

- [ ] **Step 5: `lib.rs` — 两个导出方法签名同步**

`import_item` 的 UniFFI 导出:在 `created_at: i64,` 之后加 `alias: Option<String>,`,转发调用在 `created_at,` 之后加 `alias.as_deref(),`。

`import_item_if_missing` 的 UniFFI 导出改为:

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
        alias: Option<String>,
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
            alias.as_deref(),
            &representations,
        )
    }
```

- [ ] **Step 6: 更新 `lib.rs` `mod tests` 内既有调用点**

`lib.rs` 的 `mod tests` 内既有的 `import_item` / `import_item_if_missing` 调用都缺新参数,会编译失败。统一规则:

- 所有 `import_item(...)` 调用:在 `created_at` 时间戳实参之后补一个 `None`(该测试用例无别名)。
- 所有 `import_item_if_missing(...)` 调用:在 `created_at` 时间戳实参之后、`representations` 实参(`vec![]` 或 `reps`)之前插入 `None,`。

运行 `cd rust && cargo build --tests` 用编译器逐处定位,直到编译通过。预期受影响的测试:`test_export_archive_snapshot_returns_stable_full_order`、`test_import_distinct_images_do_not_collide`、`test_import_item_if_missing_skips_duplicate_without_resetting_usage`、`test_import_item_if_missing_repairs_duplicate_image_with_missing_file`、`test_import_item_if_missing_with_representations_new`、`test_import_item_if_missing_merges_into_empty_representations`、`test_import_item_if_missing_skips_when_representations_exist`。

- [ ] **Step 7: 运行全部测试确认通过**

Run: `cd rust && cargo test --lib`
Expected: PASS — 全部测试通过,含本 task 3 个新测试。

- [ ] **Step 8: 提交**

```bash
git add rust/src/storage.rs rust/src/lib.rs
git commit -m "$(cat <<'EOF'
feat: 别名进入导入/导出备份

【根因/背景】备份应保留用户别名；导入同 hash 条目时不丢、不误覆盖别名
【踩坑记录】import_if_missing 命中已存在条目时，仅当现有 alias 为空才用备份别名补全（计为 imported），现有别名非空则保留不覆盖
【改动范围】storage.rs 与 lib.rs 的 import_item / import_item_if_missing 增加 alias 参数；既有测试调用点补 None
EOF
)"
```

---

## 最终验证

- [ ] **生成 Swift binding 并确认 Rust 整体构建通过**

Run: `./scripts/build-rust.sh`
Expected: 构建成功,`Clipin/Generated/` 下的 UniFFI binding 重新生成,新增 `setAlias` / `updateContent` 方法、`importItem*` 方法带 `alias` 参数、`ClipItem` / `ClipListItem` 带 `alias` 属性。

这是 Swift 前端计划(`2026-05-21-clip-rename-edit-content-swift.md`)的前置条件。
