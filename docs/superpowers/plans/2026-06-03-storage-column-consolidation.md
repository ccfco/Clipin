# storage.rs 列清单收口 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `rust/src/storage.rs` 里手抄约 22 次的 `ClipItem` / `ClipListItem` 投影列清单收口到两个生成函数 `item_cols(prefix)` / `list_item_cols(prefix)`,消除"加列要在 22 处精确同位插入否则整列静默错位"的风险。

**Architecture:** 列顺序成为单一真相源:两个生成函数产出带可选表别名前缀的列清单字符串,所有 `SELECT` 用 `format!` 派生;decoder(`row_to_item`/`row_to_list_item`)按 ordinal 解码不变,仅加契约注释。搜索 FTS 分支的 `, clip_fts.rank` 由调用点自行追加(rank 不是数据列)。排序语义、`WHERE`/`ORDER BY`、`LIMIT` 一字不改。最终排序仍由 `merge_search_hits` 在 Rust 层完成。

**Tech Stack:** Rust + rusqlite + SQLite/FTS5,`cargo test --lib` 为主验收,`xcodebuild test` 验跨 target。

---

## 背景:为什么先补测试

`storage.rs` 当前对 `search` / `search_list_items` **零测试覆盖**(`storage_tests.rs` 全是 migration/reconcile/trim/CASCADE)。列清单收口若把某列写错位置,decoder 的 ordinal 不变、值会静默解码到错误字段——现有测试一个都不会红。因此 **Task 1 先补特征化测试(针对当前行为,写完即应通过)** 作为收口前后的"行为不变"基线;Task 2/3 每步收口后重跑这套测试,保持全绿即证明行为未变。

## File Structure

- `rust/src/storage_tests.rs`(Modify,文件尾追加):新增搜索路径特征化测试,覆盖字段解码 + 排序 + FTS/LIKE 双分支 + 拼音 + type_filter。
- `rust/src/storage.rs`(Modify):
  - 新增 `fn item_cols(prefix: &str) -> String` / `fn list_item_cols(prefix: &str) -> String`(放在 `LIST_PREVIEW_CHARS` 常量附近或 `row_to_item` 前)。
  - 改写 10 处 `ClipItem` SELECT + 12 处 `ClipListItem` SELECT 为 `format!` 派生。
  - `row_to_item` / `row_to_list_item` 加契约注释。
- `CLAUDE.md`(Modify):把"12 处 SELECT 必须同时改"约定改写为"改 `item_cols`/`list_item_cols` + 对应 decoder"。

## 列清单权威定义(decoder 跟随此顺序)

- `item_cols`(15 列,对齐 `row_to_item` ordinal 0..=14):
  `id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count, alias, attachment_paths`
- `list_item_cols`(15 列,对齐 `row_to_list_item` ordinal 0..=14;第二列是 preview 表达式):
  `id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{P}), clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, paste_count, copy_count, image_width, image_height, alias, attachment_paths`

> 两者列顺序不同(item 是 `copy_count, first_copied_at`;list 是 `paste_count, copy_count`),是两个独立函数,不可合并。

---

### Task 1: 补搜索路径特征化测试(安全网)

**Files:**
- Modify: `rust/src/storage_tests.rs`(在文件末尾追加测试)

这些测试针对**当前**行为编写,写完即应通过——它们是收口的回归基线,不是先红后绿的 TDD。

- [ ] **Step 1: 在 `rust/src/storage_tests.rs` 末尾追加测试**

```rust
// ── 搜索路径特征化测试(列清单收口的回归基线)─────────────────────────
// 针对当前行为编写,收口前后都必须全绿。主职责:验证 search/search_list_items
// 的字段解码 ordinal 对齐;附带覆盖排序、FTS(≥3字)/LIKE(≤2字)双分支、拼音、type_filter。

fn new_storage_for_search() -> (tempfile::TempDir, Storage) {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("search.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();
    let storage = Storage::new(&db_path, &img_dir).unwrap();
    (tmp, storage)
}

#[test]
fn test_search_item_field_decoding_roundtrip() {
    // 字段解码对齐:构造各字段值互不相同的条目,搜索取回后逐字段断言,
    // 任何列错位(如 paste_count/copy_count 互换)都会被这里抓到。
    let (_tmp, storage) = new_storage_for_search();
    let item = storage
        .save_item("alpha bravo charlie", &ClipType::Text, Some("AppX"), Some("NameY"), None)
        .unwrap();
    storage.set_alias(&item.id, Some("myalias")).unwrap();
    storage.increment_paste_count(&item.id).unwrap();
    storage.increment_paste_count(&item.id).unwrap();
    storage.increment_paste_count(&item.id).unwrap(); // paste_count = 3
    storage.toggle_pin(&item.id).unwrap(); // is_pinned = true

    // FTS 路径(query ≥3 字)
    let hits = storage.search("alpha", None).unwrap();
    assert_eq!(hits.len(), 1, "应命中 1 条");
    let h = &hits[0];
    assert_eq!(h.id, item.id);
    assert_eq!(h.content, "alpha bravo charlie");
    assert_eq!(h.clip_type, ClipType::Text);
    assert_eq!(h.source_app.as_deref(), Some("AppX"));
    assert_eq!(h.source_name.as_deref(), Some("NameY"));
    assert!(h.is_pinned);
    assert_eq!(h.paste_count, 3);
    assert_eq!(h.copy_count, 1);
    assert_eq!(h.alias.as_deref(), Some("myalias"));

    // list 投影同样逐字段对齐(preview 取 content;image 尺寸对文本为 None)
    let list = storage.search_list_items("alpha", None).unwrap();
    assert_eq!(list.len(), 1);
    let l = &list[0];
    assert_eq!(l.id, item.id);
    assert!(l.preview.starts_with("alpha bravo charlie"));
    assert_eq!(l.clip_type, ClipType::Text);
    assert!(l.is_pinned);
    assert_eq!(l.paste_count, 3);
    assert_eq!(l.copy_count, 1);
    assert_eq!(l.image_width, None);
    assert_eq!(l.image_height, None);
    assert_eq!(l.alias.as_deref(), Some("myalias"));
}

#[test]
fn test_search_fts_sort_pin_then_paste() {
    // FTS(≥3字)路径排序:is_pinned > paste_count 优先级。
    let (_tmp, storage) = new_storage_for_search();
    let pinned = storage.save_item("term pinned", &ClipType::Text, None, None, None).unwrap();
    storage.toggle_pin(&pinned.id).unwrap(); // 置顶,paste=0
    let hot = storage.save_item("term hot", &ClipType::Text, None, None, None).unwrap();
    for _ in 0..5 { storage.increment_paste_count(&hot.id).unwrap(); } // paste=5,不置顶
    let cold = storage.save_item("term cold", &ClipType::Text, None, None, None).unwrap(); // paste=0

    let hits = storage.search("term", None).unwrap();
    let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
    assert_eq!(ids, vec![pinned.id.as_str(), hot.id.as_str(), cold.id.as_str()],
        "置顶优先,其次按 paste_count 降序");
}

#[test]
fn test_search_like_sort_copy_count_tiebreak() {
    // LIKE(≤2字)路径排序:同 paste_count、均不置顶时按 copy_count 降序。
    // 通过重复 save 相同内容触发 copy_count 自增(同 hash 去重 +1)。
    let (_tmp, storage) = new_storage_for_search();
    let one = storage.save_item("xy one", &ClipType::Text, None, None, None).unwrap(); // copy=1
    let two_a = storage.save_item("xy two", &ClipType::Text, None, None, None).unwrap();
    let two_b = storage.save_item("xy two", &ClipType::Text, None, None, None).unwrap(); // copy=2
    assert_eq!(two_a.id, two_b.id, "相同内容应去重为同一条目");
    let three = storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap();
    storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap();
    storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap(); // copy=3

    let hits = storage.search("xy", None).unwrap(); // 2 字 → LIKE 分支
    let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
    assert_eq!(ids, vec![three.id.as_str(), two_a.id.as_str(), one.id.as_str()],
        "copy_count 降序:three(3) > two(2) > one(1)");
}

#[test]
fn test_search_pinyin_path_hits() {
    // 拼音路径:中文内容由 compute_pinyin 写入 pinyin_flat,拼音 query 应命中。
    let (_tmp, storage) = new_storage_for_search();
    let item = storage.save_item("你好世界", &ClipType::Text, None, None, None).unwrap();
    let hits = storage.search("nihao", None).unwrap(); // ≥3 字 → 拼音 FTS
    assert!(hits.iter().any(|h| h.id == item.id), "拼音 nihao 应命中 你好世界");
}

#[test]
fn test_search_type_filter_narrows_results() {
    // type_filter 分支:同样匹配的文本 + 图片,带 Text 过滤只回文本。
    let (tmp, storage) = new_storage_for_search();
    let text = storage.save_item("term doc", &ClipType::Text, None, None, None).unwrap();
    let png = tmp.path().join("images").join("term.png");
    std::fs::write(&png, b"fake-png-bytes").unwrap();
    storage
        .save_item("term img", &ClipType::Image, None, None, Some(&png.to_string_lossy()))
        .unwrap();

    let only_text = storage.search("term", Some(&ClipType::Text)).unwrap();
    assert!(only_text.iter().all(|h| h.clip_type == ClipType::Text));
    assert!(only_text.iter().any(|h| h.id == text.id));
    let all = storage.search("term", None).unwrap();
    assert!(all.len() >= only_text.len(), "无过滤应 ≥ 有过滤");
}
```

- [ ] **Step 2: 运行测试,确认针对当前代码全绿**

Run: `cd rust && cargo test --lib`
Expected: PASS(含新增 5 个 `test_search_*`)。若某条对当前行为断言错误(如 copy_count 去重语义不符),修正断言以匹配**当前实际行为**——目的是锁定现状,不是改变它。

- [ ] **Step 3: Commit**

```bash
git add rust/src/storage_tests.rs
git commit -m "test: 补 storage 搜索路径特征化测试

【根因/背景】search/search_list_items 零测试覆盖,列清单收口若错位 decoder ordinal 不变会静默解码错字段且无测试拦截。
【改动范围】storage_tests.rs 新增 5 个 test_search_*,覆盖字段解码对齐/排序/FTS+LIKE 双分支/拼音/type_filter,作为收口回归基线。"
```

---

### Task 2: 加 `item_cols` + 收口 10 处 ClipItem SELECT

**Files:**
- Modify: `rust/src/storage.rs`

- [ ] **Step 1: 在 `row_to_item`(约 2185 行)前新增生成函数**

```rust
/// ClipItem 的 15 列投影,顺序必须与 row_to_item 的 ordinal 0..=14 一一对应。
/// 改列顺序 = 同步改本函数 + row_to_item 两处,别处不再手抄。
/// prefix: "" (裸列:浏览/LIKE/get_item) 或 "ci." (JOIN clip_fts 时消歧)。
/// FTS 分支的 `, clip_fts.rank` 由调用点自行 format! 追加,不在此函数内。
fn item_cols(prefix: &str) -> String {
    [
        "id", "content", "clip_type", "source_app", "source_name",
        "is_pinned", "created_at", "image_path", "char_count", "copy_count",
        "first_copied_at", "ocr_text", "paste_count", "alias", "attachment_paths",
    ]
    .iter()
    .map(|c| format!("{prefix}{c}"))
    .collect::<Vec<_>>()
    .join(", ")
}
```

- [ ] **Step 2: 改写 `get_items`(约 1002-1019 行)两个分支**

```rust
        if let Some(t) = type_filter {
            let filter_val = t.as_str().to_string();
            let sql = format!(
                "SELECT {} FROM clip_items WHERE clip_type = ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3",
                Self::item_cols("")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![filter_val, limit, offset], Self::row_to_item)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        } else {
            let sql = format!(
                "SELECT {} FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?1 OFFSET ?2",
                Self::item_cols("")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![limit, offset], Self::row_to_item)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        }
```

- [ ] **Step 3: 改写 `export_archive_snapshot`(约 1029-1033 行)**

```rust
            let mut stmt = conn.prepare(&format!(
                "SELECT {} FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC, id DESC",
                Self::item_cols("")
            ))?;
```

- [ ] **Step 4: 改写 `get_item`(约 1663-1669 行)**

```rust
        conn.query_row(
            &format!(
                "SELECT {} FROM clip_items WHERE id = ?1",
                Self::item_cols("")
            ),
            params![id],
            Self::row_to_item,
        )
```

- [ ] **Step 5: 改写 `get_unprocessed_images`(约 1680-1688 行)**

```rust
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM clip_items
             WHERE clip_type = 'image' AND ocr_text IS NULL
             ORDER BY created_at ASC
             LIMIT ?1",
            Self::item_cols("")
        ))?;
```

- [ ] **Step 6: 改写 `get_unsized_images`(约 1697-1705 行)**

```rust
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM clip_items
             WHERE clip_type = 'image' AND image_width IS NULL
             ORDER BY created_at ASC
             LIMIT ?1",
            Self::item_cols("")
        ))?;
```

- [ ] **Step 7: 改写 `query_raw_item_hits`(约 1289-1338 行)的两个分支**

```rust
        if search.raw.chars().count() >= 3 {
            let cols = Self::item_cols("ci.");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_fts, t.as_str()],
                    Self::row_to_item_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(params![&search.raw_fts], Self::row_to_item_search_hit)?
                    .collect()
            }
        } else {
            let cols = Self::item_cols("");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_like, t.as_str()],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_like],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            }
        }
```

- [ ] **Step 8: 改写 `query_pinyin_item_hits`(约 1372-1421 行)的两个分支**

保留分支前的注释。FTS 与 LIKE 两段 SQL 的改法与 Step 7 完全相同(FTS 用 `Self::item_cols("ci.")` + `, clip_fts.rank`;LIKE 用 `Self::item_cols("")`),仅 WHERE/参数不同:

```rust
            let cols = Self::item_cols("ci.");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            };
```

LIKE 分支(pinyin 列):

```rust
            let pattern = Self::escape_like_pattern(normalized_pinyin);
            let cols = Self::item_cols("");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE (pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            };
```

`stmt.prepare(sql)` 全部改为 `stmt.prepare(&sql)`(已是 `&sql` 的不动)。

- [ ] **Step 9: 运行测试,确认行为不变**

Run: `cd rust && cargo test --lib`
Expected: PASS(全部既有测试 + Task 1 的 5 个搜索测试)。任何字段错位会被 `test_search_item_field_decoding_roundtrip` 红掉;`ci.` 前缀漏加会让 SQL 报 ambiguous column 直接失败。

- [ ] **Step 10: Commit**

```bash
git add rust/src/storage.rs
git commit -m "refactor: storage ClipItem 投影列清单收口到 item_cols

【根因/背景】ClipItem 15 列在 10 处 SELECT 手抄,加列要同位精确插入否则 decoder ordinal 静默错位。
【踩坑记录】FTS 分支需 ci. 前缀消歧且尾随 clip_fts.rank(由调用点追加,非数据列);字面量 SELECT 改 format! 后 prepare 入参由 sql 改 &sql。
【改动范围】storage.rs 新增 item_cols(prefix);get_items/export_archive_snapshot/get_item/get_unprocessed_images/get_unsized_images/query_raw_item_hits/query_pinyin_item_hits 共 10 处 SELECT 改派生。"
```

---

### Task 3: 加 `list_item_cols` + 收口 12 处 ClipListItem SELECT

**Files:**
- Modify: `rust/src/storage.rs`

- [ ] **Step 1: 在 `item_cols` 旁新增 `list_item_cols`**

```rust
/// ClipListItem 的 15 列投影(第二列是 preview 表达式,吃 LIST_PREVIEW_CHARS),
/// 顺序必须与 row_to_list_item 的 ordinal 0..=14 一一对应。
/// 改列顺序 = 同步改本函数 + row_to_list_item 两处。prefix 与 rank 约定同 item_cols。
fn list_item_cols(prefix: &str) -> String {
    let p = Self::LIST_PREVIEW_CHARS;
    format!(
        "{prefix}id, \
         substr(COALESCE(NULLIF({prefix}ocr_text,''),{prefix}content),1,{p}), \
         {prefix}clip_type, {prefix}source_app, {prefix}source_name, {prefix}is_pinned, \
         {prefix}created_at, {prefix}image_path, {prefix}char_count, {prefix}paste_count, {prefix}copy_count, \
         {prefix}image_width, {prefix}image_height, {prefix}alias, {prefix}attachment_paths"
    )
}
```

- [ ] **Step 2: 改写 `get_list_items_with_pinned_filter`(约 1118-1191 行)的 4 个分支**

每个分支把内联的 `"SELECT id, substr(...),1,{p}), ... attachment_paths"` 列段替换为 `{cols}`,在 `format!` 前取 `let cols = Self::list_item_cols("");`。四个分支仅 WHERE/参数不同,列段一致。示例((Some,Some) 分支):

```rust
            (Some(t), Some(pinned)) => {
                let filter_val = t.as_str().to_string();
                let pinned_val = if pinned { 1 } else { 0 };
                let sql = format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE clip_type = ?1 AND is_pinned = ?2
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?3 OFFSET ?4",
                    cols = Self::list_item_cols("")
                );
                let mut stmt = conn.prepare(&sql)?;
                let rows = stmt.query_map(
                    params![filter_val, pinned_val, limit, offset],
                    Self::row_to_list_item,
                )?;
                Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
            }
```

其余三分支 WHERE/参数照原样保留,列段同样换 `{cols}` + `cols = Self::list_item_cols("")`:
- `(Some(t), None)`:`WHERE clip_type = ?1` … `LIMIT ?2 OFFSET ?3`,参数 `params![filter_val, limit, offset]`。
- `(None, Some(pinned))`:`WHERE is_pinned = ?1` … `LIMIT ?2 OFFSET ?3`,参数 `params![pinned_val, limit, offset]`。
- `(None, None)`:无 WHERE … `LIMIT ?1 OFFSET ?2`,参数 `params![limit, offset]`。

> 原来 `format!` 的 `p = Self::LIST_PREVIEW_CHARS` 命名参数删掉(preview 现由 `list_item_cols` 内部处理)。

- [ ] **Step 3: 改写 `query_raw_list_hits`(约 1443-1510 行)的两个分支**

```rust
        if search.raw.chars().count() >= 3 {
            let cols = Self::list_item_cols("ci.");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_fts, t.as_str()],
                    Self::row_to_list_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(params![&search.raw_fts], Self::row_to_list_search_hit)?
                    .collect()
            }
        } else {
            let cols = Self::list_item_cols("");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_like, t.as_str()],
                    Self::row_to_list_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![&search.raw_like],
                    Self::row_to_list_search_hit_without_rank,
                )?
                .collect()
            }
        }
```

- [ ] **Step 4: 改写 `query_pinyin_list_hits`(约 1535-1609 行)的两个分支**

保留分支前注释。FTS 分支用 `Self::list_item_cols("ci.")` + `, clip_fts.rank`;LIKE 分支用 `Self::list_item_cols("")`,WHERE 用 pinyin 列:

```rust
            let cols = Self::list_item_cols("ci.");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}, clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200"
                )
            };
```

LIKE 分支:

```rust
            let pattern = Self::escape_like_pattern(normalized_pinyin);
            let cols = Self::list_item_cols("");
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE (pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            };
```

- [ ] **Step 5: 运行测试**

Run: `cd rust && cargo test --lib`
Expected: PASS。`test_search_*` 的 list 字段断言(preview/paste_count/copy_count/image_width)守护 list 投影 ordinal 对齐。

- [ ] **Step 6: Commit**

```bash
git add rust/src/storage.rs
git commit -m "refactor: storage ClipListItem 投影列清单收口到 list_item_cols

【根因/背景】ClipListItem 15 列(含 preview 表达式)在 12 处 SELECT 手抄,与 item 投影列顺序不同(paste_count/copy_count 在前),易错位。
【踩坑记录】preview 的 substr(COALESCE(NULLIF(ocr_text,''),content),1,P) 前缀要钻进表达式内部的 ocr_text/content;LIST_PREVIEW_CHARS 由函数内部插值,调用点删 p= 命名参数。
【改动范围】storage.rs 新增 list_item_cols(prefix);get_list_items_with_pinned_filter 4 分支 + query_raw_list_hits/query_pinyin_list_hits 共 12 处 SELECT 改派生。"
```

---

### Task 4: decoder 契约注释 + CLAUDE.md 约定更新

**Files:**
- Modify: `rust/src/storage.rs`(`row_to_item` / `row_to_list_item`)
- Modify: `CLAUDE.md`

- [ ] **Step 1: `row_to_item`(约 2185 行)加契约注释**

在 `fn row_to_item` 上方插入:

```rust
    /// ClipItem 行解码:ordinal 0..=14 必须与 item_cols 的列顺序逐位对应。
    /// 改列顺序只动 item_cols + 本函数两处,各 SELECT 全部由 item_cols 派生不再手抄。
```

- [ ] **Step 2: `row_to_list_item`(约 2223 行)加契约注释**

在 `fn row_to_list_item` 上方插入:

```rust
    /// ClipListItem 行解码:ordinal 0..=14 必须与 list_item_cols 的列顺序逐位对应
    /// (注意与 item_cols 顺序不同:此处 paste_count 在 copy_count 之前)。
    /// 改列顺序只动 list_item_cols + 本函数两处。FTS rank 固定在 ordinal 15。
```

- [ ] **Step 3: 更新 `CLAUDE.md` 的列约定条目**

找到 `存储与搜索` 节里 `ClipListItem 按列序号解码` 那条,替换为:

```markdown
- **ClipItem/ClipListItem 投影列只由 item_cols/list_item_cols 单一函数派生,加列只能追加在尾部**:所有读取 SELECT(浏览/搜索 FTS/LIKE 各路径)用 `format!` 从这两个函数取列,改列顺序只动函数 + 对应 decoder(row_to_item/row_to_list_item)两处;FTS 路径的 clip_fts.rank 由调用点追加且永远排在所有数据列之后(ordinal 15)。两个投影列顺序不同不可合并。任何错位会让整列静默解码到错误字段。
```

- [ ] **Step 4: 编译确认 + Commit**

Run: `cd rust && cargo test --lib`
Expected: PASS(仅加注释,不改逻辑)。

```bash
git add rust/src/storage.rs CLAUDE.md
git commit -m "docs: storage decoder 契约注释 + CLAUDE.md 列约定改为函数收口

【改动范围】row_to_item/row_to_list_item 加 ordinal↔列函数契约注释;CLAUDE.md「12 处 SELECT 必须同时改」改写为「改 item_cols/list_item_cols + 对应 decoder」。"
```

---

### Task 5: 跨 target 验收 + Codex review

**Files:** 无改动,仅验证。

- [ ] **Step 1: 跑跨 target 测试(同 CI)**

Run:
```bash
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```
Expected: BUILD/TEST SUCCEEDED。先确保 `./scripts/build-rust.sh` 已重新生成 bindings(若 Rust 改了导出签名——本次未改 pub API,可跳过,但 storage.rs 变动后稳妥起见重建一次)。

- [ ] **Step 2: Codex 子 agent review**

按 CLAUDE.md「写完代码默认 Codex review」,对本次 storage.rs 收口 diff 做一次 review,重点:列顺序与 decoder 是否完全对齐、`ci.` 前缀在所有 FTS 分支齐全、preview 表达式前缀注入正确、有无遗漏的 SELECT 未收口。

- [ ] **Step 3: 终态确认**

`cargo test --lib` 与 `xcodebuild test` 均绿、Codex 无阻断问题 → 收口完成。

---

## Self-Review

**Spec coverage:** spec 的方案(函数收口/SQL 派生/decoder 注释/前置补测试/CLAUDE.md 更新)逐项对应 Task 1-4;验收(cargo + xcodebuild + Codex)对应 Task 5。非目标(INSERT 列清单、搜索 SQL 构造器、ViewModel)未出现在任何 Task。✓

**Placeholder scan:** 无 TBD/TODO;所有 SQL、测试、提交信息均为完整内容。✓

**Type consistency:** `item_cols(&str)->String` / `list_item_cols(&str)->String` 在 Task 2/3 定义与各调用点签名一致;`row_to_item`/`row_to_list_item` 名称全文一致;`Self::LIST_PREVIEW_CHARS` 引用与现有常量一致。✓

**已知行为不变性论据:** 收口只改 SELECT 列清单的"书写来源",生成的列名/顺序/preview 表达式/rank 位置与原 SQL 逐字等价;`WHERE`/`ORDER BY`/`LIMIT`/参数绑定/decoder ordinal 全部不动;最终排序仍由 `merge_search_hits` 在 Rust 完成。Task 1 的特征化测试在收口前后均跑,绿即证不变。
