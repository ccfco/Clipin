use super::*;
use rusqlite::Connection;

#[test]
fn test_fresh_db_is_version_1() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 12, "新建数据库应为 v12");
}

#[test]
fn test_existing_v0_migrates_to_v1() {
    // 模拟旧版本数据库（user_version=0，没有 schema）
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("legacy.db");
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    // 先建一个空的旧数据库（version=0）
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch("PRAGMA user_version = 0;").unwrap();
    }

    // Storage::new 应自动 migrate 到 v1
    let storage = Storage::new(&db_path.to_string_lossy(), &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 12, "旧数据库应 migrate 到 v12");

    // 数据表应已创建
    let conn = storage.conn.lock().unwrap();
    let count: i32 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='clip_items'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, 1, "clip_items 表应存在");
}

#[test]
fn test_migration_is_idempotent() {
    // 同一个数据库 open 两次，不应报错也不应重置数据
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let s1 = Storage::new(&db_path, &img_dir).unwrap();
    drop(s1);

    // 第二次 open 不应出错
    let s2 = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(s2.schema_version(), 12);
}

#[test]
fn test_v8_adds_browse_indexes_and_narrows_fts_update_trigger() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let conn = storage.conn.lock().unwrap();

    let browse_index_count: i32 = conn
        .query_row(
            "SELECT count(*) FROM sqlite_master
             WHERE type='index'
               AND name IN ('idx_pinned_created_at', 'idx_type_pinned_created_at')",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(browse_index_count, 2);

    let trigger_sql: String = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='clip_items_au'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    // v8 收窄了 clip_items_au 的 UPDATE OF 列集；v11 重建 FTS 时在该列集追加了 alias。
    // 此处断言的是当前 head schema 的触发器形态，故跟随 v11 的列集。
    assert!(trigger_sql.contains(
        "AFTER UPDATE OF content, source_name, ocr_text, alias, pinyin_flat, pinyin_initials"
    ));
}

#[test]
fn test_v9_creates_representations_table() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let conn = storage.conn.lock().unwrap();
    let table_exists: i32 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='clip_representations'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(table_exists, 1);
}

#[test]
fn test_v10_image_dimensions_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();
    let storage = Storage::new(&db_path, &img_dir).unwrap();

    // save_item 对 image 类型会读文件算内容 hash，需先落一个真实文件
    let png_path = tmp.path().join("images").join("x.png");
    std::fs::write(&png_path, b"fake-png-bytes").unwrap();
    let png_path = png_path.to_string_lossy().to_string();
    let item = storage
        .save_item("image", &ClipType::Image, None, None, Some(&png_path))
        .unwrap();

    // 新图片尚未测量尺寸：backfill 查询能扫到，ClipListItem 尺寸为 None
    let pending = storage.get_unsized_images(10).unwrap();
    assert_eq!(pending.len(), 1, "未测量图片应进入 backfill 候选");
    let before = storage.get_list_items(10, 0, None).unwrap();
    assert_eq!(before[0].image_width, None);
    assert_eq!(before[0].image_height, None);

    // 写入尺寸后：ClipListItem 暴露宽高，backfill 候选清空
    storage
        .update_image_dimensions(&item.id, 1920, 1080)
        .unwrap();
    let after = storage.get_list_items(10, 0, None).unwrap();
    assert_eq!(after[0].image_width, Some(1920));
    assert_eq!(after[0].image_height, Some(1080));
    assert!(
        storage.get_unsized_images(10).unwrap().is_empty(),
        "已测量图片不应再进入 backfill 候选"
    );
}

#[test]
fn test_v10_migration_is_reentrant() {
    // 模拟「v10 的 ALTER 已提交、user_version 还没推进就崩溃」：列已存在、
    // 版本回退到 9。重新打开不应因 duplicate column 报错——migrate_to_v10
    // 的 table_info 逐列判存保证可重入。
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    Storage::new(&db_path, &img_dir).unwrap(); // 正常建库到 v10
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch("PRAGMA user_version = 9;").unwrap();
    }
    // 列还在、版本回到 9 → migrate_to_v10 必须跳过 ALTER；随后继续跑 v11/v12 到 head。
    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 12);
}

#[test]
fn test_v11_adds_alias_column_and_rebuilds_fts() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 12);

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

#[test]
fn test_v12_adds_attachment_paths_column() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let conn = storage.conn.lock().unwrap();

    let has_attachment_paths: bool = conn
        .prepare("PRAGMA table_info(clip_items)")
        .unwrap()
        .query_map([], |row| row.get::<_, String>(1))
        .unwrap()
        .any(|name| name.as_deref() == Ok("attachment_paths"));
    assert!(has_attachment_paths, "clip_items 应有 attachment_paths 列");
}

#[test]
fn test_v12_migration_is_reentrant() {
    // 与 v10/v11 测试同款套路：列已存在时 migrate 必须跳过 ALTER 而不是抛 duplicate column
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    Storage::new(&db_path, &img_dir).unwrap(); // 正常建库到 v12
    {
        let conn = Connection::open(&db_path).unwrap();
        conn.execute_batch("PRAGMA user_version = 11;").unwrap();
    }
    // 列还在、版本回到 11 → migrate_to_v12 必须跳过 ALTER
    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 12);
}

#[test]
fn test_reconcile_orphan_attachments_protects_recent_files() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images");
    std::fs::create_dir_all(&img_dir).unwrap();
    let img_dir_str = img_dir.to_string_lossy().to_string();
    let storage = Storage::new(&db_path, &img_dir_str).unwrap();

    // 写一个孤儿 PNG，立刻 reconcile(300) → 5 分钟保护应让它幸存
    let fresh = img_dir.join("fresh_0.png");
    std::fs::write(&fresh, b"fresh").unwrap();

    let removed = storage.reconcile_orphan_attachments(300).unwrap();
    assert_eq!(removed, 0, "刚写的孤儿应被 mtime 保护");
    assert!(fresh.exists(), "新文件应受 mtime 保护不被删");
}

#[test]
fn test_reconcile_orphan_attachments_deletes_aged_orphans() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images");
    std::fs::create_dir_all(&img_dir).unwrap();
    let img_dir_str = img_dir.to_string_lossy().to_string();
    let storage = Storage::new(&db_path, &img_dir_str).unwrap();

    let aged = img_dir.join("aged_0.png");
    std::fs::write(&aged, b"aged").unwrap();
    // 用 max_age_seconds=0 模拟"任何文件都已超出保护期"——
    // 比修改文件 mtime 更可靠（filetime 标准库 set_modified 是 Rust 1.75+）。
    let removed = storage.reconcile_orphan_attachments(0).unwrap();
    assert_eq!(removed, 1, "超出保护期的孤儿应被删");
    assert!(!aged.exists(), "孤儿 PNG 应已清理");
}

#[test]
fn test_reconcile_orphan_attachments_keeps_referenced_files() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images");
    std::fs::create_dir_all(&img_dir).unwrap();
    let img_dir_str = img_dir.to_string_lossy().to_string();
    let storage = Storage::new(&db_path, &img_dir_str).unwrap();

    // 创建一个真实被引用的 attachment（写盘 + 入库带 attachment_paths）
    let referenced = storage
        .write_attachment_png("test-item-id", 0, b"referenced")
        .unwrap();
    let attachment_json = format!("[\"{}\"]", referenced);
    storage
        .save_item_with_attachment_paths(
            Some("test-item-id"),
            "/tmp/foo.jpg",
            &ClipType::File,
            None,
            None,
            None,
            Some(&attachment_json),
            &[],
        )
        .unwrap();

    // 0 秒保护窗口：所有未被引用的孤儿都应被立刻删
    let removed = storage.reconcile_orphan_attachments(0).unwrap();
    assert_eq!(removed, 0, "被引用的 PNG 不应被误删");
    assert!(
        std::path::Path::new(&referenced).exists(),
        "被引用的 PNG 必须保留"
    );
}

#[test]
fn test_non_fts_updates_do_not_rewrite_fts_index() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let item = storage
        .save_item("hello", &ClipType::Text, None, None, None)
        .unwrap();

    let before = storage.conn.lock().unwrap().total_changes();
    storage.increment_paste_count(&item.id).unwrap();
    let after_paste_count = storage.conn.lock().unwrap().total_changes();
    assert_eq!(after_paste_count - before, 1);

    storage.touch_item(&item.id).unwrap();
    let after_touch = storage.conn.lock().unwrap().total_changes();
    assert_eq!(after_touch - after_paste_count, 1);

    storage.toggle_pin(&item.id).unwrap();
    let after_pin = storage.conn.lock().unwrap().total_changes();
    assert_eq!(after_pin - after_touch, 1);
}

#[test]
fn test_trim_unpinned_keeps_newest_items() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("trim.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let base = chrono::Utc::now().timestamp_millis();

    storage
        .import_item(
            "old",
            &ClipType::Text,
            None,
            None,
            None,
            false,
            base - 2_000,
            None,
        )
        .unwrap();
    storage
        .import_item(
            "mid",
            &ClipType::Text,
            None,
            None,
            None,
            false,
            base - 1_000,
            None,
        )
        .unwrap();
    storage
        .import_item("new", &ClipType::Text, None, None, None, false, base, None)
        .unwrap();

    let removed = storage.trim_unpinned(2).unwrap();
    assert_eq!(removed, 1);

    let items = storage.get_items(10, 0, None).unwrap();
    let contents: Vec<String> = items.into_iter().map(|item| item.content).collect();
    assert_eq!(contents, vec!["new", "mid"]);
}

#[test]
fn test_trim_unpinned_preserves_pinned_items() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp
        .path()
        .join("trim_pinned.db")
        .to_string_lossy()
        .to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    let base = chrono::Utc::now().timestamp_millis();

    storage
        .import_item(
            "pinned",
            &ClipType::Text,
            None,
            None,
            None,
            true,
            base - 3_000,
            None,
        )
        .unwrap();
    storage
        .import_item(
            "one",
            &ClipType::Text,
            None,
            None,
            None,
            false,
            base - 2_000,
            None,
        )
        .unwrap();
    storage
        .import_item(
            "two",
            &ClipType::Text,
            None,
            None,
            None,
            false,
            base - 1_000,
            None,
        )
        .unwrap();

    let removed = storage.trim_unpinned(1).unwrap();
    assert_eq!(removed, 1);

    let items = storage.get_items(10, 0, None).unwrap();
    assert_eq!(items.len(), 2);
    assert!(
        items
            .iter()
            .any(|item| item.content == "pinned" && item.is_pinned)
    );
    assert!(
        items
            .iter()
            .any(|item| item.content == "two" && !item.is_pinned)
    );
}

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

#[test]
fn test_insert_and_load_representations() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();

    let item = storage.save_item_with_representations(
        "hi", &ClipType::Text, None, None, None,
        &[
            ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() },
            ClipRepresentation { uti: "public.rtf".into(),  data: b"{\\rtf1 hi}".to_vec() },
        ],
    ).unwrap();

    let loaded = storage.load_representations(&item.id).unwrap();
    assert_eq!(loaded.len(), 2);
    assert!(loaded.iter().any(|r| r.uti == "public.html" && r.data == b"<p>hi</p>"));
}

#[test]
fn test_delete_item_cascades_representations() {
    let tmpfile = tempfile::NamedTempFile::new().unwrap();
    let tmpdir = tempfile::tempdir().unwrap();
    let storage = Storage::new(
        tmpfile.path().to_str().unwrap(),
        tmpdir.path().to_str().unwrap(),
    ).unwrap();

    let item = storage.save_item_with_representations(
        "hi", &ClipType::Text, None, None, None,
        &[ClipRepresentation { uti: "public.html".into(), data: b"<p>hi</p>".to_vec() }],
    ).unwrap();

    storage.delete_item(&item.id).unwrap();

    let loaded = storage.load_representations(&item.id).unwrap();
    assert_eq!(loaded.len(), 0, "ON DELETE CASCADE should have removed representations");
}

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
    // 同 hash 重存走 INSERT OR REPLACE:换新 id、copy_count+1,旧行被替换,
    // 所以幸存条目是"最后一次 save"返回的 ClipItem(其 copy_count 已是累计值)。
    let (_tmp, storage) = new_storage_for_search();
    let one = storage.save_item("xy one", &ClipType::Text, None, None, None).unwrap(); // copy=1
    storage.save_item("xy two", &ClipType::Text, None, None, None).unwrap();
    let two = storage.save_item("xy two", &ClipType::Text, None, None, None).unwrap(); // copy=2
    storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap();
    storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap();
    let three = storage.save_item("xy three", &ClipType::Text, None, None, None).unwrap(); // copy=3
    assert_eq!(one.copy_count, 1);
    assert_eq!(two.copy_count, 2);
    assert_eq!(three.copy_count, 3);

    let hits = storage.search("xy", None).unwrap(); // 2 字 → LIKE 分支
    let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
    assert_eq!(ids, vec![three.id.as_str(), two.id.as_str(), one.id.as_str()],
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

#[test]
fn test_search_source_name_short_query_like_fallback() {
    // source_name 匹配的长短查询语义必须一致:FTS(≥3字)搜四列
    // (content/source_name/ocr_text/alias),LIKE(≤2字)回退分支曾漏 source_name,
    // 导致"微信"这类 2 字来源 App 名静默无结果而 3 字却能命中。
    let (tmp, storage) = new_storage_for_search();
    let item = storage
        .save_item("完全不相关的内容", &ClipType::Text, Some("com.tencent.xinWeChat"), Some("微信"), None)
        .unwrap();
    let ctrl = storage
        .save_item("另一条不相关内容", &ClipType::Text, Some("com.tencent.WeWork"), Some("WeChat"), None)
        .unwrap();

    // FTS 路径(≥3 字)按 source_name 命中——既有语义,作对照
    let fts_hits = storage.search("WeChat", None).unwrap();
    assert!(fts_hits.iter().any(|h| h.id == ctrl.id), "FTS 路径应按 source_name 命中");

    // LIKE 路径(2 字)必须同样按 source_name 命中:item / list / type_filter 三分支
    let hits = storage.search("微信", None).unwrap();
    assert!(hits.iter().any(|h| h.id == item.id), "LIKE 无过滤分支应按 source_name 命中");
    let list = storage.search_list_items("微信", None).unwrap();
    assert!(list.iter().any(|l| l.id == item.id), "LIKE list 分支应按 source_name 命中");
    let filtered = storage.search("微信", Some(&ClipType::Text)).unwrap();
    assert!(filtered.iter().any(|h| h.id == item.id), "LIKE type_filter 分支应按 source_name 命中");
    let filtered_list = storage.search_list_items("微信", Some(&ClipType::Text)).unwrap();
    assert!(filtered_list.iter().any(|l| l.id == item.id), "LIKE list type_filter 分支应按 source_name 命中");

    drop(tmp);
}
