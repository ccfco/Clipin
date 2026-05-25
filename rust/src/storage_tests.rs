use super::*;
use rusqlite::Connection;

#[test]
fn test_fresh_db_is_version_1() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 11, "新建数据库应为 v11");
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
    assert_eq!(storage.schema_version(), 11, "旧数据库应 migrate 到 v11");

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
    assert_eq!(s2.schema_version(), 11);
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
    // 列还在、版本回到 9 → migrate_to_v10 必须跳过 ALTER；随后继续跑 v11 到 head。
    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 11);
}

#[test]
fn test_v11_adds_alias_column_and_rebuilds_fts() {
    let tmp = tempfile::tempdir().unwrap();
    let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
    let img_dir = tmp.path().join("images").to_string_lossy().to_string();
    std::fs::create_dir_all(&img_dir).unwrap();

    let storage = Storage::new(&db_path, &img_dir).unwrap();
    assert_eq!(storage.schema_version(), 11);

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
