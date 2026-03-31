use crate::models::*;
use pinyin::ToPinyin;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::{collections::HashSet, fs, io::ErrorKind, sync::Mutex};
use uuid::Uuid;

/// 把文本中的 CJK 字符转为拼音（无声调）：
/// - flat: 所有音节连续拼接，例如 "你好" → "nihao"
/// - initials: 每个音节首字母，例如 "你好" → "nh"
/// 非 CJK 字符直接跳过，只处理前 500 个字符（性能保障）。
fn compute_pinyin(content: &str) -> (String, String) {
    let limited: String = content.chars().take(500).collect();
    let mut flat = String::new();
    let mut initials = String::new();
    for py_opt in (&*limited).to_pinyin() {
        if let Some(py) = py_opt {
            let syllable: &str = py.plain();
            flat.push_str(syllable);
            if let Some(c) = syllable.chars().next() {
                initials.push(c);
            }
        }
    }
    (flat, initials)
}

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
        let version: i32 = {
            let conn = self.conn.lock().unwrap();
            conn.query_row("PRAGMA user_version", [], |r| r.get(0))?
        };
        self.run_migrations(version)
    }

    /// 按版本号顺序执行 migration，每个版本只跑一次。
    /// v1-v4 纯 SQL；v5 需要 Rust 计算拼音故分两阶段。
    fn run_migrations(&self, from_version: i32) -> Result<(), ClipinError> {
        // v1-v4: 纯 SQL，单次持锁执行完
        {
        let conn = self.conn.lock().unwrap();
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

        if from_version < 2 {
            // 检查列是否已存在（防止重复 ALTER 崩溃）
            let has_copy_count: bool = conn
                .prepare("PRAGMA table_info(clip_items)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .any(|name| name.as_deref() == Ok("copy_count"));

            if !has_copy_count {
                // DROP 触发器避免 UPDATE 时触发大量无效 FTS 写入（v3 会重建 FTS）
                conn.execute_batch(
                    "DROP TRIGGER IF EXISTS clip_items_ai;
                     DROP TRIGGER IF EXISTS clip_items_ad;
                     DROP TRIGGER IF EXISTS clip_items_au;
                     ALTER TABLE clip_items ADD COLUMN copy_count INTEGER NOT NULL DEFAULT 1;
                     ALTER TABLE clip_items ADD COLUMN first_copied_at INTEGER NOT NULL DEFAULT 0;
                     UPDATE clip_items SET first_copied_at = created_at WHERE first_copied_at = 0;",
                )?;
            }
            conn.execute_batch("PRAGMA user_version = 2;")?;
        }

        if from_version < 3 {
            // 重建 FTS5 虚拟表，使用 trigram tokenizer 支持任意子串搜索
            conn.execute_batch(
                "
                DROP TRIGGER IF EXISTS clip_items_ai;
                DROP TRIGGER IF EXISTS clip_items_ad;
                DROP TRIGGER IF EXISTS clip_items_au;
                DROP TABLE IF EXISTS clip_fts;

                CREATE VIRTUAL TABLE clip_fts USING fts5(
                    content,
                    source_name,
                    content='clip_items',
                    content_rowid='rowid',
                    tokenize='trigram'
                );

                CREATE TRIGGER clip_items_ai AFTER INSERT ON clip_items BEGIN
                    INSERT INTO clip_fts(rowid, content, source_name)
                    VALUES (new.rowid, new.content, new.source_name);
                END;

                CREATE TRIGGER clip_items_ad AFTER DELETE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name)
                    VALUES ('delete', old.rowid, old.content, old.source_name);
                END;

                CREATE TRIGGER clip_items_au AFTER UPDATE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name)
                    VALUES ('delete', old.rowid, old.content, old.source_name);
                    INSERT INTO clip_fts(rowid, content, source_name)
                    VALUES (new.rowid, new.content, new.source_name);
                END;

                INSERT INTO clip_fts(rowid, content, source_name)
                SELECT rowid, content, source_name FROM clip_items;

                PRAGMA user_version = 3;
                ",
            )?;
        }

        if from_version < 4 {
            // 添加 OCR 文字列，并重建 FTS5 以索引 ocr_text，使图片内容可搜索
            conn.execute_batch(
                "
                ALTER TABLE clip_items ADD COLUMN ocr_text TEXT;

                DROP TRIGGER IF EXISTS clip_items_ai;
                DROP TRIGGER IF EXISTS clip_items_ad;
                DROP TRIGGER IF EXISTS clip_items_au;
                DROP TABLE IF EXISTS clip_fts;

                CREATE VIRTUAL TABLE clip_fts USING fts5(
                    content,
                    source_name,
                    ocr_text,
                    content='clip_items',
                    content_rowid='rowid',
                    tokenize='trigram'
                );

                CREATE TRIGGER clip_items_ai AFTER INSERT ON clip_items BEGIN
                    INSERT INTO clip_fts(rowid, content, source_name, ocr_text)
                    VALUES (new.rowid, new.content, new.source_name, new.ocr_text);
                END;

                CREATE TRIGGER clip_items_ad AFTER DELETE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name, ocr_text)
                    VALUES ('delete', old.rowid, old.content, old.source_name, old.ocr_text);
                END;

                CREATE TRIGGER clip_items_au AFTER UPDATE ON clip_items BEGIN
                    INSERT INTO clip_fts(clip_fts, rowid, content, source_name, ocr_text)
                    VALUES ('delete', old.rowid, old.content, old.source_name, old.ocr_text);
                    INSERT INTO clip_fts(rowid, content, source_name, ocr_text)
                    VALUES (new.rowid, new.content, new.source_name, new.ocr_text);
                END;

                INSERT INTO clip_fts(rowid, content, source_name, ocr_text)
                SELECT rowid, content, source_name, ocr_text FROM clip_items;

                PRAGMA user_version = 4;
                ",
            )?;
        }
        } // end v1-v4 locked block

        // v5: 添加 pinyin 列、重建 FTS5 索引、回填拼音
        if from_version < 5 {
            // --- SQL 阶段 1：添加列 + 重建 FTS schema + 更新触发器 ---
            {
                let conn = self.conn.lock().unwrap();

                // 幂等检查：防止崩溃重启时重复 ALTER
                let has_pinyin: bool = conn
                    .prepare("PRAGMA table_info(clip_items)")?
                    .query_map([], |row| row.get::<_, String>(1))?
                    .any(|n| n.as_deref() == Ok("pinyin_flat"));

                if !has_pinyin {
                    conn.execute_batch(
                        "ALTER TABLE clip_items ADD COLUMN pinyin_flat     TEXT NOT NULL DEFAULT '';
                         ALTER TABLE clip_items ADD COLUMN pinyin_initials TEXT NOT NULL DEFAULT '';",
                    )?;
                }

                // 先建空 FTS 和触发器，再插入数据，避免 INSERT SELECT + 触发器双重写入
                conn.execute_batch(
                    "DROP TRIGGER IF EXISTS clip_items_ai;
                     DROP TRIGGER IF EXISTS clip_items_ad;
                     DROP TRIGGER IF EXISTS clip_items_au;
                     DROP TABLE   IF EXISTS clip_fts;

                     CREATE VIRTUAL TABLE clip_fts USING fts5(
                         content, source_name, ocr_text, pinyin_flat, pinyin_initials,
                         content='clip_items', content_rowid='rowid', tokenize='trigram'
                     );

                     CREATE TRIGGER clip_items_ai AFTER INSERT ON clip_items BEGIN
                         INSERT INTO clip_fts(rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                         VALUES(new.rowid,new.content,new.source_name,new.ocr_text,new.pinyin_flat,new.pinyin_initials);
                     END;

                     CREATE TRIGGER clip_items_ad AFTER DELETE ON clip_items BEGIN
                         INSERT INTO clip_fts(clip_fts,rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                         VALUES('delete',old.rowid,old.content,old.source_name,old.ocr_text,old.pinyin_flat,old.pinyin_initials);
                     END;

                     CREATE TRIGGER clip_items_au AFTER UPDATE ON clip_items BEGIN
                         INSERT INTO clip_fts(clip_fts,rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                         VALUES('delete',old.rowid,old.content,old.source_name,old.ocr_text,old.pinyin_flat,old.pinyin_initials);
                         INSERT INTO clip_fts(rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                         VALUES(new.rowid,new.content,new.source_name,new.ocr_text,new.pinyin_flat,new.pinyin_initials);
                     END;

                     INSERT INTO clip_fts(rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                     SELECT rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials FROM clip_items;",
                )?;
            }

            // --- Rust 阶段：UPDATE 触发 clip_items_au 进行 DELETE+INSERT，实现带拼音的原位更新 ---
            self.backfill_pinyin_v5()?;

            // --- 提交版本号 ---
            {
                let conn = self.conn.lock().unwrap();
                conn.execute_batch("PRAGMA user_version = 5;")?;
            }
        }

        // v6: 添加 paste_count（粘贴次数），作为首要排序信号
        if from_version < 6 {
            let conn = self.conn.lock().unwrap();
            let has_paste_count: bool = conn
                .prepare("PRAGMA table_info(clip_items)")?
                .query_map([], |row| row.get::<_, String>(1))?
                .any(|n| n.as_deref() == Ok("paste_count"));
            if !has_paste_count {
                conn.execute_batch(
                    "ALTER TABLE clip_items ADD COLUMN paste_count INTEGER NOT NULL DEFAULT 0;",
                )?;
            }
            conn.execute_batch("PRAGMA user_version = 6;")?;
        }

        Ok(())
    }

    /// v5 migration 专用：批量计算并回填现有条目的拼音列
    fn backfill_pinyin_v5(&self) -> Result<(), ClipinError> {
        // 一次性读取全部需要回填的条目（rowid + content）
        let items: Vec<(i64, String)> = {
            let conn = self.conn.lock().unwrap();
            let mut stmt = conn.prepare("SELECT rowid, content FROM clip_items")?;
            stmt.query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))?
                .filter_map(|r| r.ok())
                .collect()
        };
        if items.is_empty() {
            return Ok(());
        }
        // 批量更新，有中文才写（pinyin_flat='',initials='' 已是 DEFAULT）
        let mut conn = self.conn.lock().unwrap();
        let tx = conn.transaction()?;
        for (rowid, content) in items {
            let (flat, initials) = compute_pinyin(&content);
            if !flat.is_empty() {
                tx.execute(
                    "UPDATE clip_items SET pinyin_flat=?1, pinyin_initials=?2 WHERE rowid=?3",
                    params![flat, initials, rowid],
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    fn content_hash(content: &str, clip_type: &ClipType) -> String {
        let mut hasher = Sha256::new();
        hasher.update(clip_type.as_str().as_bytes());
        hasher.update(b":");
        hasher.update(content.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    fn content_hash_bytes(bytes: &[u8], clip_type: &ClipType) -> String {
        let mut hasher = Sha256::new();
        hasher.update(clip_type.as_str().as_bytes());
        hasher.update(b":");
        hasher.update(bytes);
        format!("{:x}", hasher.finalize())
    }

    fn hash_for_item(
        content: &str,
        clip_type: &ClipType,
        image_path: Option<&str>,
    ) -> Result<String, ClipinError> {
        match clip_type {
            ClipType::Image => {
                if let Some(path) = image_path {
                    let bytes = fs::read(path)?;
                    Ok(Self::content_hash_bytes(&bytes, clip_type))
                } else {
                    Ok(Self::content_hash(content, clip_type))
                }
            }
            _ => Ok(Self::content_hash(content, clip_type)),
        }
    }

    fn load_image_paths_for_hash(conn: &Connection, hash: &str) -> Result<Vec<String>, ClipinError> {
        let mut stmt =
            conn.prepare("SELECT image_path FROM clip_items WHERE hash = ?1 AND image_path IS NOT NULL")?;
        let rows = stmt.query_map(params![hash], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn load_image_paths_for_item(conn: &Connection, id: &str) -> Result<Vec<String>, ClipinError> {
        let mut stmt =
            conn.prepare("SELECT image_path FROM clip_items WHERE id = ?1 AND image_path IS NOT NULL")?;
        let rows = stmt.query_map(params![id], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn load_image_paths_before(
        conn: &Connection,
        timestamp: i64,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path
             FROM clip_items
             WHERE is_pinned = 0 AND created_at < ?1 AND image_path IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![timestamp], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn load_trimmed_image_paths(
        conn: &Connection,
        keep_latest: i32,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "
            SELECT image_path
            FROM clip_items
            WHERE is_pinned = 0
              AND image_path IS NOT NULL
              AND id IN (
                  SELECT id
                  FROM clip_items
                  WHERE is_pinned = 0
                  ORDER BY created_at DESC
                  LIMIT -1 OFFSET ?1
              )
            ",
        )?;
        let rows = stmt.query_map(params![keep_latest], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn remove_image_files(paths: Vec<String>, keep_path: Option<&str>) {
        let keep_path = keep_path.map(str::to_string);
        let mut unique_paths = HashSet::new();

        for path in paths {
            if keep_path.as_deref() == Some(path.as_str()) || !unique_paths.insert(path.clone()) {
                continue;
            }

            if let Err(err) = fs::remove_file(&path) {
                if err.kind() != ErrorKind::NotFound {
                    eprintln!("⚠️ Failed to remove image file {}: {}", path, err);
                }
            }
        }
    }

    pub fn save_item(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<ClipItem, ClipinError> {
        let mut conn = self.conn.lock().unwrap();
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let now = chrono::Utc::now().timestamp_millis();
        let char_count = content.chars().count() as i32;
        let (pinyin_flat, pinyin_initials) = compute_pinyin(content);

        // 去重：查找已有记录，保留 first_copied_at 和累加 copy_count
        let existing: Option<(i64, i32, bool)> = conn
            .query_row(
                "SELECT first_copied_at, copy_count, is_pinned FROM clip_items WHERE hash = ?1",
                params![hash],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .ok();

        let (first_copied_at, copy_count, is_pinned) = match existing {
            Some((first, count, pinned)) => (first, count + 1, pinned),
            None => (now, 1, false),
        };

        let old_image_paths = Self::load_image_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = Uuid::new_v4().to_string();
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
            params![
                id,
                content,
                clip_type.as_str(),
                source_app,
                source_name,
                is_pinned,
                now,
                image_path,
                char_count,
                hash,
                copy_count,
                first_copied_at,
                pinyin_flat,
                pinyin_initials,
            ],
        )?;
        tx.commit()?;
        Self::remove_image_files(old_image_paths, image_path);

        Ok(ClipItem {
            id,
            content: content.to_string(),
            clip_type: clip_type.clone(),
            source_app: source_app.map(String::from),
            source_name: source_name.map(String::from),
            is_pinned,
            created_at: now,
            image_path: image_path.map(String::from),
            char_count,
            copy_count,
            first_copied_at,
            ocr_text: None,
            paste_count: 0,
        })
    }

    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();
        let sql;

        let result = if let Some(t) = type_filter {
            let filter_val = t.as_str().to_string();
            sql = format!(
                "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items WHERE clip_type = ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3"
            );
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![filter_val, limit, offset], Self::row_to_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            sql = format!(
                "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?1 OFFSET ?2"
            );
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![limit, offset], Self::row_to_item)
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
        let sql;

        let result = if let Some(t) = type_filter {
            let filter_val = t.as_str().to_string();
            sql = format!(
                "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                        clip_type, source_app, source_name, is_pinned,
                        created_at, image_path, char_count, paste_count, copy_count
                 FROM clip_items
                 WHERE clip_type = ?1
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?2 OFFSET ?3",
                p = Self::LIST_PREVIEW_CHARS
            );
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![filter_val, limit, offset], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        } else {
            sql = format!(
                "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                        clip_type, source_app, source_name, is_pinned,
                        created_at, image_path, char_count, paste_count, copy_count
                 FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC
                 LIMIT ?1 OFFSET ?2",
                p = Self::LIST_PREVIEW_CHARS
            );
            conn.prepare(&sql).and_then(|mut stmt| {
                stmt.query_map(params![limit, offset], Self::row_to_list_item)
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
            })
        };

        result.unwrap_or_default()
    }

    /// 转义 FTS5 MATCH 查询：wrap 到双引号（phrase query），内部的 " 翻倍
    fn escape_fts5_query(query: &str) -> String {
        format!("\"{}\"", query.replace('"', "\"\""))
    }

    pub fn search(&self, query: &str, type_filter: Option<&ClipType>) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();

        // trigram 需要 ≥3 字符；短查询回退 LIKE（同时搜拼音列）
        if query.chars().count() >= 3 {
            let fts_query = Self::escape_fts5_query(query);
            // paste_count 首要，BM25 rank 次之，copy_count/created_at 保底
            let sql = if type_filter.is_some() {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            } else {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            };
            let result = if let Some(t) = type_filter {
                conn.prepare(sql).and_then(|mut stmt| {
                    stmt.query_map(params![fts_query, t.as_str()], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            } else {
                conn.prepare(sql).and_then(|mut stmt| {
                    stmt.query_map(params![fts_query], Self::row_to_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            };
            result.unwrap_or_default()
        } else {
            // 短查询：LIKE 覆盖 content / ocr_text / pinyin_flat / pinyin_initials
            let pattern = format!("%{}%", query);
            let sql = if type_filter.is_some() {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE (content LIKE ?1 OR ocr_text LIKE ?1 OR pinyin_flat LIKE ?1 OR pinyin_initials LIKE ?1)
                   AND clip_type = ?2
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
            } else {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE content LIKE ?1 OR ocr_text LIKE ?1 OR pinyin_flat LIKE ?1 OR pinyin_initials LIKE ?1
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
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
    }

    pub fn search_list_items(
        &self,
        query: &str,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        let conn = self.conn.lock().unwrap();

        if query.chars().count() >= 3 {
            let fts_query = Self::escape_fts5_query(query);
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            } else {
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            };
            let result = if let Some(t) = type_filter {
                conn.prepare(&sql).and_then(|mut stmt| {
                    stmt.query_map(params![fts_query, t.as_str()], Self::row_to_list_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            } else {
                conn.prepare(&sql).and_then(|mut stmt| {
                    stmt.query_map(params![fts_query], Self::row_to_list_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            };
            result.unwrap_or_default()
        } else {
            let pattern = format!("%{}%", query);
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE (content LIKE ?1 OR ocr_text LIKE ?1 OR pinyin_flat LIKE ?1 OR pinyin_initials LIKE ?1)
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            } else {
                format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE content LIKE ?1 OR ocr_text LIKE ?1 OR pinyin_flat LIKE ?1 OR pinyin_initials LIKE ?1
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
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
    }

    pub fn get_item(&self, id: &str) -> Result<ClipItem, ClipinError> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
             FROM clip_items
             WHERE id = ?1",
            params![id],
            Self::row_to_item,
        )
        .map_err(|_| ClipinError::NotFound {
            id: id.to_string(),
        })
    }

    /// OCR backfill 专用：直接查 ocr_text IS NULL，无需 offset，不受新增条目影响
    pub fn get_unprocessed_images(&self, limit: i32) -> Vec<ClipItem> {
        let conn = self.conn.lock().unwrap();
        conn.prepare(
            "SELECT id, content, clip_type, source_app, source_name,
                    is_pinned, created_at, image_path, char_count, copy_count,
                    first_copied_at, ocr_text, paste_count
             FROM clip_items
             WHERE clip_type = 'image' AND ocr_text IS NULL
             ORDER BY created_at ASC
             LIMIT ?1",
        )
        .and_then(|mut stmt| {
            stmt.query_map(params![limit], Self::row_to_item)
                .map(|rows| rows.filter_map(|r| r.ok()).collect())
        })
        .unwrap_or_default()
    }

    pub fn update_ocr_text(&self, id: &str, ocr_text: &str) -> Result<(), ClipinError> {
        let conn = self.conn.lock().unwrap();
        let affected = conn.execute(
            "UPDATE clip_items SET ocr_text = ?1 WHERE id = ?2",
            params![ocr_text, id],
        )?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        Ok(())
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
        let image_paths = Self::load_image_paths_for_item(&conn, id)?;
        let affected = conn.execute("DELETE FROM clip_items WHERE id = ?1", params![id])?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        Self::remove_image_files(image_paths, None);
        Ok(())
    }

    /// 更新 created_at 为当前时间，使条目浮到列表顶部
    pub fn touch_item(&self, id: &str) -> Result<(), ClipinError> {
        let conn = self.conn.lock().unwrap();
        let now = chrono::Utc::now().timestamp_millis();
        let affected = conn.execute(
            "UPDATE clip_items SET created_at = ?1 WHERE id = ?2",
            params![now, id],
        )?;
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
        let mut conn = self.conn.lock().unwrap();
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let old_image_paths = Self::load_image_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count() as i32;
        let (pinyin_flat, pinyin_initials) = compute_pinyin(content);

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
        tx.commit()?;
        Self::remove_image_files(old_image_paths, image_path);

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
            copy_count: 1,
            first_copied_at: created_at,
            ocr_text: None,
            paste_count: 0,
        })
    }

    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let image_paths = Self::load_image_paths_before(&conn, timestamp)?;
        let affected = conn.execute(
            "DELETE FROM clip_items WHERE is_pinned = 0 AND created_at < ?1",
            params![timestamp],
        )?;
        if affected > 0 {
            Self::remove_image_files(image_paths, None);
        }
        Ok(affected as i32)
    }

    /// 保留最新 N 条未 pin 记录，其余删除
    pub fn trim_unpinned(&self, keep_latest: i32) -> Result<i32, ClipinError> {
        let conn = self.conn.lock().unwrap();
        let keep_latest = keep_latest.max(0);
        let image_paths = Self::load_trimmed_image_paths(&conn, keep_latest)?;
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
        if affected > 0 {
            Self::remove_image_files(image_paths, None);
        }
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
            copy_count: row.get(9)?,
            first_copied_at: row.get(10)?,
            ocr_text: row.get(11)?,
            paste_count: row.get(12).unwrap_or(0),
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
            paste_count: row.get(9).unwrap_or(0),
            copy_count: row.get(10).unwrap_or(1),
        })
    }

    pub fn increment_paste_count(&self, id: &str) -> Result<(), ClipinError> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "UPDATE clip_items SET paste_count = paste_count + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
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
        assert_eq!(storage.schema_version(), 6, "新建数据库应为 v5");
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
        assert_eq!(storage.schema_version(), 6, "旧数据库应 migrate 到 v5");

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
        assert_eq!(s2.schema_version(), 6);
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
