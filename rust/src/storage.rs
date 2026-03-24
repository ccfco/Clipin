use crate::models::*;
use rusqlite::{params, Connection};
use sha2::{Digest, Sha256};
use std::sync::Mutex;
use uuid::Uuid;

pub struct Storage {
    conn: Mutex<Connection>,
    image_dir: String,
}

impl Storage {
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
            ",
        )?;
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
            conn.prepare(&sql)
                .and_then(|mut stmt| {
                    stmt.query_map(params![filter_val, limit, offset], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
        } else {
            conn.prepare(&sql)
                .and_then(|mut stmt| {
                    stmt.query_map(params!["", limit, offset], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
        };

        result.unwrap_or_default()
    }

    pub fn search(&self, query: &str, type_filter: Option<&ClipType>) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();

        // FTS5 搜索
        let fts_query = format!("\"{}\"", query.replace('"', "\"\""));

        let sql = if type_filter.is_some() {
            "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                    ci.is_pinned, ci.created_at, ci.image_path, ci.char_count
             FROM clip_items ci
             JOIN clip_fts ON ci.rowid = clip_fts.rowid
             WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
             ORDER BY ci.is_pinned DESC, rank
             LIMIT 50"
        } else {
            "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                    ci.is_pinned, ci.created_at, ci.image_path, ci.char_count
             FROM clip_items ci
             JOIN clip_fts ON ci.rowid = clip_fts.rowid
             WHERE clip_fts MATCH ?1
             ORDER BY ci.is_pinned DESC, rank
             LIMIT 50"
        };

        let result = if let Some(t) = type_filter {
            conn.prepare(sql)
                .and_then(|mut stmt| {
                    stmt.query_map(params![fts_query, t.as_str()], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
        } else {
            conn.prepare(sql)
                .and_then(|mut stmt| {
                    stmt.query_map(params![fts_query], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
        };

        result.unwrap_or_default()
    }

    pub fn toggle_pin(&self, id: &str) -> Result<bool, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let current: bool = conn
            .query_row(
                "SELECT is_pinned FROM clip_items WHERE id = ?1",
                params![id],
                |row| row.get(0),
            )
            .map_err(|_| ClipinError::NotFound {
                id: id.to_string(),
            })?;

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
            return Err(ClipinError::NotFound {
                id: id.to_string(),
            });
        }
        Ok(())
    }

    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute(
            "DELETE FROM clip_items WHERE is_pinned = 0 AND created_at < ?1",
            params![timestamp],
        )?;
        Ok(affected as i32)
    }

    pub fn image_dir(&self) -> &str {
        &self.image_dir
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
}
