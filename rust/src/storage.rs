use crate::models::*;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::sync::Mutex;
use uuid::Uuid;

pub struct Storage {
    conn: Mutex<Connection>,
    image_dir: String,
}

impl Storage {
    const LIST_PREVIEW_CHARS: i32 = 240;

    pub fn new(db_path: &str, image_dir: &str) -> Result<Self, ClipinError> {
        let conn = Connection::open(db_path)?;
        let storage = Storage {
            conn: Mutex::new(conn),
            image_dir: image_dir.to_string(),
        };
        storage.init_schema()?;
        Ok(storage)
    }

    fn init_schema(&self) -> Result<(), ClipinError> {
        let conn = self.conn.lock().unwrap();
        let version: i32 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        Self::run_migrations(&conn, version)
    }

    /// 按版本号顺序执行 migration，每个版本只跑一次。
    /// 新增字段时在这里加 v2、v3…，已发布版本的 migration 不可修改。
    fn run_migrations(conn: &Connection, from_version: i32) -> Result<(), ClipinError> {
        if from_version < 1 {
            conn.execute_batch(
                "
                CREATE TABLE IF NOT EXISTS clip_items (
                    id          TEXT PRIMARY KEY,
                    content     TEXT NOT NULL DEFAULT '',
                    clip_type   TEXT NOT NULL DEFAULT 'text',
                    source_app  TEXT,
                    source_name TEXT,
                    is_pinned   INTEGER NOT NULL DEFAULT 0,
                    created_at  INTEGER NOT NULL,
                    image_path  TEXT,
                    char_count  INTEGER NOT NULL DEFAULT 0,
                    hash        TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_created_at ON clip_items(created_at DESC);
                CREATE INDEX IF NOT EXISTS idx_clip_type ON clip_items(clip_type);
                CREATE INDEX IF NOT EXISTS idx_is_pinned ON clip_items(is_pinned);
                CREATE INDEX IF NOT EXISTS idx_hash ON clip_items(hash);

                CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
                    content,
                    source_name,
                    content='clip_items',
                    content_rowid='rowid'
                );

                CREATE TRIGGER IF NOT EXISTS clip_items_ai AFTER INSERT ON clip_items BEGIN
                    INSERT INTO clip_fts(rowid, content, source_name)
                    VALUES (new.rowid, new.content, new.source_name);
                END;

                CREATE TRIGGER IF NOT EXISTS clip_items_ad AFTER DELETE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name)
                    VALUES ('delete', old.rowid, old.content, old.source_name);
                END;

                CREATE TRIGGER IF NOT EXISTS clip_items_au AFTER UPDATE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name)
                    VALUES ('delete', old.rowid, old.content, old.source_name);
                    INSERT INTO clip_fts(rowid, content, source_name)
                    VALUES (new.rowid, new.content, new.source_name);
                END;

                PRAGMA user_version = 1;
                ",
            )?;
        }

        // 未来加字段示例（v2）：
        // if from_version < 2 {
        //     conn.execute_batch("
        //         ALTER TABLE clip_items ADD COLUMN tags TEXT NOT NULL DEFAULT '';
        //         PRAGMA user_version = 2;
        //     ")?;
        // }

        Ok(())
    }

    fn content_hash(content: &str, clip_type: &ClipType) -> String {
        let mut hasher = Sha256::new();
        hasher.update(clip_type.as_str().as_bytes());
        hasher.update(b":");
        hasher.update(content.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    pub fn save_item(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<ClipItem, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let hash = Self::content_hash(content, clip_type);

        // 去重：相同内容删除旧记录（保留最新）
        conn.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = Uuid::new_v4().to_string();
        let now = chrono::Utc::now().timestamp_millis();
        let char_count = content.chars().count() as i32;

        conn.execute(
            "INSERT INTO clip_items (id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, hash)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9)",
            params![
                id,
                content,
                clip_type.as_str(),
                source_app,
                source_name,
                now,
                image_path,
                char_count,
                hash,
            ],
        )?;

        Ok(ClipItem {
            id,
            content: content.to_string(),
            clip_type: clip_type.clone(),
            source_app: source_app.map(String::from),
            source_name: source_name.map(String::from),
            is_pinned: false,
            created_at: now,
            image_path: image_path.map(String::from),
            char_count,
        })
    }

    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();
        let (sql, filter_val);

        if let Some(t) = type_filter {
            filter_val = t.as_str().to_string();
            sql = format!(
                "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count
                 FROM clip_items WHERE clip_type = ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3"
            );
        } else {
            filter_val = String::new();
            sql = format!(
                "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count
                 FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3"
            );
        }

        let result = if type_filter.is_some() {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![filter_val, limit, offset], Self::row_to_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params!["", limit, offset], Self::row_to_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        };

        result.unwrap_or_default()
    }

    pub fn get_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        let conn = self.conn.lock().unwrap();
        let (sql, filter_val);

        if let Some(t) = type_filter {
            filter_val = t.as_str().to_string();
            sql = format!(
                "SELECT id, substr(content, 1, {preview_chars}), clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count
                 FROM clip_items
                 WHERE clip_type = ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3",
                preview_chars = Self::LIST_PREVIEW_CHARS
            );
        } else {
            filter_val = String::new();
            sql = format!(
                "SELECT id, substr(content, 1, {preview_chars}), clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count
                 FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3",
                preview_chars = Self::LIST_PREVIEW_CHARS
            );
        }

        let result = if type_filter.is_some() {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![filter_val, limit, offset], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params!["", limit, offset], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        };

        result.unwrap_or_default()
    }

    pub fn search(&self, query: &str, type_filter: Option<&ClipType>) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();
        let pattern = format!("%{}%", query);

        let sql = if type_filter.is_some() {
            "SELECT id, content, clip_type, source_app, source_name,
                    is_pinned, created_at, image_path, char_count
             FROM clip_items
             WHERE content LIKE ?1 AND clip_type = ?2
             ORDER BY is_pinned DESC, created_at DESC
             LIMIT 50"
        } else {
            "SELECT id, content, clip_type, source_app, source_name,
                    is_pinned, created_at, image_path, char_count
             FROM clip_items
             WHERE content LIKE ?1
             ORDER BY is_pinned DESC, created_at DESC
             LIMIT 50"
        };

        let result = if let Some(t) = type_filter {
            conn.prepare(sql).and_then(|mut stmt| {
                stmt.query_map(params![pattern, t.as_str()], Self::row_to_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            conn.prepare(sql).and_then(|mut stmt| {
                stmt.query_map(params![pattern], Self::row_to_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        };

        result.unwrap_or_default()
    }

    pub fn search_list_items(
        &self,
        query: &str,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        let conn = self.conn.lock().unwrap();
        let pattern = format!("%{}%", query);

        let sql = if type_filter.is_some() {
            format!(
                "SELECT id, substr(content, 1, {preview_chars}), clip_type, source_app,
                        source_name, is_pinned, created_at, image_path, char_count
                 FROM clip_items
                 WHERE content LIKE ?1 AND clip_type = ?2
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT 50",
                preview_chars = Self::LIST_PREVIEW_CHARS
            )
        } else {
            format!(
                "SELECT id, substr(content, 1, {preview_chars}), clip_type, source_app,
                        source_name, is_pinned, created_at, image_path, char_count
                 FROM clip_items
                 WHERE content LIKE ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT 50",
                preview_chars = Self::LIST_PREVIEW_CHARS
            )
        };

        let result = if let Some(t) = type_filter {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![pattern, t.as_str()], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![pattern], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        };

        result.unwrap_or_default()
    }

    pub fn get_item(&self, id: &str) -> Result<ClipItem, ClipinError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count
             FROM clip_items
             WHERE id = ?1",
            params![id],
            Self::row_to_item,
        )
        .map_err(|_| ClipinError::NotFound {
            id: id.to_string(),
        })
    }

    pub fn toggle_pin(&self, id: &str) -> Result<bool, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let current: bool = conn
            .query_row(
                "SELECT is_pinned FROM clip_items WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .map_err(|_| ClipinError::NotFound { id: id.to_string() })?;

        let new_val = !current;
        conn.execute(
            "UPDATE clip_items SET is_pinned = ?1 WHERE id = ?2",
            params![new_val, id],
        )?;
        Ok(new_val)
    }

    pub fn delete_item(&self, id: &str) -> Result<(), ClipinError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute("DELETE FROM clip_items WHERE id = ?1", params![id])?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        Ok(())
    }

    /// 导入一条记录（保留原始 created_at 和 is_pinned）
    pub fn import_item(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        is_pinned: bool,
        created_at: i64,
    ) -> Result<ClipItem, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let hash = Self::content_hash(content, clip_type);
        conn.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count() as i32;

        conn.execute(
            "INSERT INTO clip_items (id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, hash)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                id, content, clip_type.as_str(), source_app, source_name,
                is_pinned as i32, created_at, image_path, char_count, hash
            ],
        )?;

        Ok(ClipItem {
            id,
            content: content.to_string(),
            clip_type: clip_type.clone(),
            source_app: source_app.map(String::from),
            source_name: source_name.map(String::from),
            is_pinned,
            created_at,
            image_path: image_path.map(String::from),
            char_count,
        })
    }

    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute(
            "DELETE FROM clip_items WHERE is_pinned = 0 AND created_at < ?1",
            params![timestamp],
        )?;
        Ok(affected as i32)
    }

    /// 保留最新 N 条未 pin 记录，其余删除
    pub fn trim_unpinned(&self, keep_latest: i32) -> Result<i32, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let keep_latest = keep_latest.max(0);
        let affected = conn.execute(
            "
            DELETE FROM clip_items
            WHERE is_pinned = 0
              AND id IN (
                  SELECT id
                  FROM clip_items
                  WHERE is_pinned = 0
                  ORDER BY created_at DESC
                  LIMIT -1 OFFSET ?1
              )
            ",
            params![keep_latest],
        )?;
        Ok(affected as i32)
    }

    pub fn image_dir(&self) -> &str {
        &self.image_dir
    }

    /// 当前 schema 版本号，用于验证 migration 已正确执行
    #[cfg(test)]
    pub fn schema_version(&self) -> i32 {
        let conn = self.conn.lock().unwrap();
        conn.query_row("PRAGMA user_version", [], |r| r.get(0))
            .unwrap_or(0)
    }

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
        })
    }

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
        })
    }
}

#[cfg(test)]
mod migration_tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn test_fresh_db_is_version_1() {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test.db").to_string_lossy().to_string();
        let img_dir = tmp.path().join("images").to_string_lossy().to_string();
        std::fs::create_dir_all(&img_dir).unwrap();

        let storage = Storage::new(&db_path, &img_dir).unwrap();
        assert_eq!(storage.schema_version(), 1, "新建数据库应为 v1");
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
        assert_eq!(storage.schema_version(), 1, "旧数据库应 migrate 到 v1");

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
        assert_eq!(s2.schema_version(), 1);
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
            )
            .unwrap();
        storage
            .import_item("new", &ClipType::Text, None, None, None, false, base)
            .unwrap();

        let removed = storage.trim_unpinned(2).unwrap();
        assert_eq!(removed, 1);

        let items = storage.get_items(10, 0, None);
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
            )
            .unwrap();

        let removed = storage.trim_unpinned(1).unwrap();
        assert_eq!(removed, 1);

        let items = storage.get_items(10, 0, None);
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
}
