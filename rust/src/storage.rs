use crate::models::*;
use pinyin::ToPinyin;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::ErrorKind,
    path::Path,
    sync::{Mutex, MutexGuard},
};
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

#[derive(Clone, Copy, Debug)]
struct PreservedItemState {
    first_copied_at: i64,
    copy_count: i32,
    paste_count: i32,
    is_pinned: bool,
}

#[derive(Clone, Debug)]
struct SearchQuery {
    raw: String,
    raw_fts: String,
    raw_like: String,
    normalized_pinyin: Option<String>,
}

#[derive(Clone, Debug)]
struct SearchHit<T: SearchSortable> {
    item: T,
    raw_rank: Option<f64>,
}

trait SearchSortable: Clone {
    fn item_id(&self) -> &str;
    fn item_is_pinned(&self) -> bool;
    fn item_paste_count(&self) -> i32;
    fn item_copy_count(&self) -> i32;
    fn item_created_at(&self) -> i64;
}

impl Storage {
    const LIST_PREVIEW_CHARS: i32 = 240;

    /// 拿到底层 SQLite 连接的独占锁。
    /// 单进程内 SQLite 是单写者，靠这个 Mutex 串行化所有读写。
    /// `expect` 而不是 `unwrap`：mutex 中毒（持锁线程 panic）必须立即暴露而不是无声崩。
    #[inline]
    fn conn(&self) -> MutexGuard<'_, Connection> {
        self.conn.lock().expect("storage connection mutex poisoned")
    }

    fn build_search_query(query: &str) -> SearchQuery {
        let raw = query.trim().to_string();
        SearchQuery {
            raw_fts: Self::build_fts5_query_for_columns(
                &raw,
                &["content", "source_name", "ocr_text"],
            ),
            raw_like: Self::escape_like_pattern(&raw),
            normalized_pinyin: Self::normalize_pinyin_query(&raw),
            raw,
        }
    }

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

    fn init_schema(&self) -> Result<(), ClipinError> {
        let version: i32 = {
            let conn = self.conn();
            conn.query_row("PRAGMA user_version", [], |r| r.get(0))?
        };
        self.run_migrations(version)
    }

    /// 按版本号顺序执行 migration，每个版本只跑一次。
    /// 每个 vN 拆成独立函数，老 migration 完全冻结，未来加 v9 只需追加一个函数 + 一个 if 分支。
    fn run_migrations(&self, from_version: i32) -> Result<(), ClipinError> {
        if from_version < 1 {
            Self::migrate_to_v1(&self.conn())?;
        }
        if from_version < 2 {
            Self::migrate_to_v2(&self.conn())?;
        }
        if from_version < 3 {
            Self::migrate_to_v3(&self.conn())?;
        }
        if from_version < 4 {
            Self::migrate_to_v4(&self.conn())?;
        }
        if from_version < 5 {
            // 拼音回填需要调用 Rust 端 compute_pinyin，必须把 lock 释放给 backfill_pinyin 自己重新获取
            Self::migrate_to_v5_schema(&self.conn())?;
            self.backfill_pinyin()?;
            self.conn().execute_batch("PRAGMA user_version = 5;")?;
        }
        if from_version < 6 {
            Self::migrate_to_v6(&self.conn())?;
        }
        if from_version < 7 {
            // 修复 v5 被手动跳过（PRAGMA user_version=5）导致的 pinyin 回填缺失
            // backfill_pinyin 只处理 pinyin_flat='' 的条目，已有 pinyin 的不动
            self.backfill_pinyin()?;
            self.conn().execute_batch("PRAGMA user_version = 7;")?;
        }
        if from_version < 8 {
            Self::migrate_to_v8(&self.conn())?;
        }
        if from_version < 9 {
            Self::migrate_to_v9(&self.conn())?;
        }
        Ok(())
    }

    fn migrate_to_v1(conn: &Connection) -> Result<(), ClipinError> {
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
        Ok(())
    }

    fn migrate_to_v2(conn: &Connection) -> Result<(), ClipinError> {
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
        Ok(())
    }

    fn migrate_to_v3(conn: &Connection) -> Result<(), ClipinError> {
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
        Ok(())
    }

    fn migrate_to_v4(conn: &Connection) -> Result<(), ClipinError> {
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
        Ok(())
    }

    /// v5 schema 阶段：加列 + 重建 FTS + 拷贝旧数据。
    /// 拼音回填在主流程里调用 `backfill_pinyin`，最后单独提交 `user_version = 5`。
    fn migrate_to_v5_schema(conn: &Connection) -> Result<(), ClipinError> {
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
        Ok(())
    }

    fn migrate_to_v6(conn: &Connection) -> Result<(), ClipinError> {
        // paste_count（粘贴次数）作为首要排序信号
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
        Ok(())
    }

    fn migrate_to_v8(conn: &Connection) -> Result<(), ClipinError> {
        // 浏览分页组合索引 + 收窄 FTS UPDATE 触发器：
        // paste_count / created_at / is_pinned 这类排序信号更新不应重写 FTS 索引。
        conn.execute_batch(
            "
            CREATE INDEX IF NOT EXISTS idx_pinned_created_at
                ON clip_items(is_pinned DESC, created_at DESC);
            CREATE INDEX IF NOT EXISTS idx_type_pinned_created_at
                ON clip_items(clip_type, is_pinned DESC, created_at DESC);

            DROP TRIGGER IF EXISTS clip_items_au;
            CREATE TRIGGER clip_items_au
            AFTER UPDATE OF content, source_name, ocr_text, pinyin_flat, pinyin_initials
            ON clip_items BEGIN
                INSERT INTO clip_fts(clip_fts,rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                VALUES('delete',old.rowid,old.content,old.source_name,old.ocr_text,old.pinyin_flat,old.pinyin_initials);
                INSERT INTO clip_fts(rowid,content,source_name,ocr_text,pinyin_flat,pinyin_initials)
                VALUES(new.rowid,new.content,new.source_name,new.ocr_text,new.pinyin_flat,new.pinyin_initials);
            END;

            PRAGMA user_version = 8;
            ",
        )?;
        Ok(())
    }

    fn migrate_to_v9(conn: &Connection) -> Result<(), ClipinError> {
        // 副表存放 text/url 条目的额外 UTI representation (HTML/RTF/RTFD/URL)
        // 主表 clip_items 保持 plain text 不变，搜索/排序/FTS 逻辑零改动
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

    /// 批量计算并回填拼音列（只处理 pinyin_flat 为空的条目，幂等可重复调用）
    fn backfill_pinyin(&self) -> Result<(), ClipinError> {
        // 只选取尚未回填的条目，已有 pinyin 的跳过（避免多余 FTS UPDATE）
        let items: Vec<(i64, String)> = {
            let conn = self.conn();
            let mut stmt =
                conn.prepare("SELECT rowid, content FROM clip_items WHERE pinyin_flat = ''")?;
            stmt.query_map([], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
            })?
            .filter_map(|r| r.ok())
            .collect()
        };
        if items.is_empty() {
            return Ok(());
        }
        // 批量更新，有中文才写（pinyin_flat='',initials='' 已是 DEFAULT）
        let mut conn = self.conn();
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

    fn load_image_paths_for_hash(
        conn: &Connection,
        hash: &str,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path FROM clip_items WHERE hash = ?1 AND image_path IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![hash], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn load_item_id_for_hash(conn: &Connection, hash: &str) -> Result<Option<String>, ClipinError> {
        conn.query_row(
            "SELECT id FROM clip_items WHERE hash = ?1 ORDER BY created_at DESC LIMIT 1",
            params![hash],
            |row| row.get(0),
        )
        .map(Some)
        .or_else(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other.into()),
        })
    }

    fn load_image_paths_for_item(conn: &Connection, id: &str) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path FROM clip_items WHERE id = ?1 AND image_path IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![id], |row| row.get::<_, String>(0))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    fn load_preserved_item_state_for_hash(
        conn: &Connection,
        hash: &str,
    ) -> Result<Option<PreservedItemState>, ClipinError> {
        conn.query_row(
            "SELECT first_copied_at, copy_count, paste_count, is_pinned
             FROM clip_items
             WHERE hash = ?1",
            params![hash],
            |row| {
                Ok(PreservedItemState {
                    first_copied_at: row.get(0)?,
                    copy_count: row.get(1)?,
                    paste_count: row.get(2).unwrap_or(0),
                    is_pinned: row.get(3)?,
                })
            },
        )
        .map(Some)
        .or_else(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other.into()),
        })
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
        self.save_item_with_representations(
            content,
            clip_type,
            source_app,
            source_name,
            image_path,
            &[],
        )
    }

    /// 保存一条剪贴板记录（自动去重），并在**同一事务**内写入 representations。
    /// item 与其 representations 必须原子落库：save_item 的 `DELETE FROM clip_items`
    /// 会通过 `ON DELETE CASCADE` 清掉旧同 hash 条目的副表行；若 rep 写入不在同一
    /// 事务内（旧实现 commit 后再单独取锁写副表），进程在两步之间中断会留下
    /// 「有 item 无 rep」的部分状态，富文本格式静默丢失。
    pub fn save_item_with_representations(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        representations: &[ClipRepresentation],
    ) -> Result<ClipItem, ClipinError> {
        // 锁外提前计算：fs::read（图片 hash）和 compute_pinyin 是 I/O / CPU 密集操作，
        // 不需要 DB 连接，持锁期间执行会阻塞所有其他存储调用（包括主线程的 getListItems）
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let now = chrono::Utc::now().timestamp_millis();
        let char_count = content.chars().count() as i32;
        let (pinyin_flat, pinyin_initials) = compute_pinyin(content);
        let mut conn = self.conn();

        // 同一 hash 表示同一个语义条目：重新复制时只刷新当前快照，不丢累计行为信号。
        let preserved = match Self::load_preserved_item_state_for_hash(&conn, &hash)? {
            Some(existing) => PreservedItemState {
                first_copied_at: existing.first_copied_at,
                copy_count: existing.copy_count + 1,
                paste_count: existing.paste_count,
                is_pinned: existing.is_pinned,
            },
            None => PreservedItemState {
                first_copied_at: now,
                copy_count: 1,
                paste_count: 0,
                is_pinned: false,
            },
        };

        let old_image_paths = Self::load_image_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = Uuid::new_v4().to_string();
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,paste_count,pinyin_flat,pinyin_initials)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)",
            params![
                id,
                content,
                clip_type.as_str(),
                source_app,
                source_name,
                preserved.is_pinned,
                now,
                image_path,
                char_count,
                hash,
                preserved.copy_count,
                preserved.first_copied_at,
                preserved.paste_count,
                pinyin_flat,
                pinyin_initials,
            ],
        )?;
        for rep in representations {
            tx.execute(
                "INSERT OR REPLACE INTO clip_representations (item_id, uti, data) VALUES (?1, ?2, ?3)",
                params![id, rep.uti, rep.data],
            )?;
        }
        tx.commit()?;
        Self::remove_image_files(old_image_paths, image_path);

        Ok(ClipItem {
            id,
            content: content.to_string(),
            clip_type: clip_type.clone(),
            source_app: source_app.map(String::from),
            source_name: source_name.map(String::from),
            is_pinned: preserved.is_pinned,
            created_at: now,
            image_path: image_path.map(String::from),
            char_count,
            copy_count: preserved.copy_count,
            first_copied_at: preserved.first_copied_at,
            ocr_text: None,
            paste_count: preserved.paste_count,
        })
    }

    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipItem> {
        let conn = self.conn();
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

    pub fn export_items_snapshot(&self) -> Vec<ClipItem> {
        let conn = self.conn();
        let result = conn.prepare(
            "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
             FROM clip_items
             ORDER BY is_pinned DESC, created_at DESC, id DESC",
        ).and_then(|mut stmt| {
            stmt.query_map([], Self::row_to_item)
                .map(|rows| rows.filter_map(|r| r.ok()).collect())
        });

        result.unwrap_or_default()
    }

    /// 导出专用：在同一把锁内一次性读出 items 与各自的 representations。
    /// 不能像旧路径那样先 `export_items_snapshot` 再逐条 `load_representations`——
    /// 两次取锁之间条目可能被删除/CASCADE，导致导出的 v2 archive 丢 representations。
    /// items 顺序与 `export_items_snapshot` 一致（is_pinned DESC, created_at DESC, id DESC）。
    pub fn export_archive_snapshot(&self) -> Result<Vec<ArchiveSnapshotItem>, ClipinError> {
        let conn = self.conn();
        let items: Vec<ClipItem> = {
            let mut stmt = conn.prepare(
                "SELECT id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC, id DESC",
            )?;
            let rows = stmt.query_map([], Self::row_to_item)?;
            rows.filter_map(|r| r.ok()).collect()
        };

        let mut rep_stmt = conn.prepare(
            "SELECT uti, data FROM clip_representations WHERE item_id = ?1 ORDER BY uti",
        )?;
        let mut result = Vec::with_capacity(items.len());
        for item in items {
            let reps = rep_stmt
                .query_map(params![item.id], |row| {
                    Ok(ClipRepresentation {
                        uti: row.get(0)?,
                        data: row.get(1)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            result.push(ArchiveSnapshotItem {
                item,
                representations: reps,
            });
        }
        Ok(result)
    }

    pub fn get_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, None)
    }

    pub fn get_pinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, Some(true))
    }

    pub fn get_unpinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, Some(false))
    }

    fn get_list_items_with_pinned_filter(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
        pinned_filter: Option<bool>,
    ) -> Vec<ClipListItem> {
        let conn = self.conn();
        let sql;

        let result = match (type_filter, pinned_filter) {
            (Some(t), Some(pinned)) => {
                let filter_val = t.as_str().to_string();
                let pinned_val = if pinned { 1 } else { 0 };
                sql = format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE clip_type = ?1 AND is_pinned = ?2
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?3 OFFSET ?4",
                    p = Self::LIST_PREVIEW_CHARS
                );
                conn.prepare(&sql).and_then(|mut stmt| {
                    stmt.query_map(
                        params![filter_val, pinned_val, limit, offset],
                        Self::row_to_list_item,
                    )
                    .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            }
            (Some(t), None) => {
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
            }
            (None, Some(pinned)) => {
                let pinned_val = if pinned { 1 } else { 0 };
                sql = format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE is_pinned = ?1
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?2 OFFSET ?3",
                    p = Self::LIST_PREVIEW_CHARS
                );
                conn.prepare(&sql).and_then(|mut stmt| {
                    stmt.query_map(params![pinned_val, limit, offset], Self::row_to_list_item)
                        .map(|rows| rows.filter_map(|r| r.ok()).collect())
                })
            }
            (None, None) => {
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
            }
        };

        result.unwrap_or_default()
    }

    /// 转义 FTS5 phrase query，内部的 " 翻倍。
    fn escape_fts5_phrase(query: &str) -> String {
        format!("\"{}\"", query.replace('"', "\"\""))
    }

    fn build_fts5_query_for_columns(query: &str, columns: &[&str]) -> String {
        let phrase = Self::escape_fts5_phrase(query);
        columns
            .iter()
            .map(|column| format!("{column}:{phrase}"))
            .collect::<Vec<_>>()
            .join(" OR ")
    }

    /// 转义 LIKE 查询的元字符（% 和 _），配合 SQL 中的 ESCAPE '\' 子句使用
    fn escape_like_pattern(query: &str) -> String {
        let escaped = query
            .replace('\\', "\\\\")
            .replace('%', "\\%")
            .replace('_', "\\_");
        format!("%{}%", escaped)
    }

    fn normalize_pinyin_query(query: &str) -> Option<String> {
        let mut normalized = String::new();

        for ch in query.chars() {
            if ch.is_ascii_alphanumeric() {
                normalized.push(ch.to_ascii_lowercase());
            } else if ch.is_whitespace() || ch == '\'' || ch == '-' {
                continue;
            } else {
                return None;
            }
        }

        if normalized.is_empty() {
            None
        } else {
            Some(normalized)
        }
    }

    fn compare_search_hits<T: SearchSortable>(
        lhs: &SearchHit<T>,
        rhs: &SearchHit<T>,
    ) -> std::cmp::Ordering {
        rhs.item
            .item_is_pinned()
            .cmp(&lhs.item.item_is_pinned())
            .then_with(|| {
                rhs.item
                    .item_paste_count()
                    .cmp(&lhs.item.item_paste_count())
            })
            .then_with(|| match (&lhs.raw_rank, &rhs.raw_rank) {
                (Some(left), Some(right)) => {
                    left.partial_cmp(right).unwrap_or(std::cmp::Ordering::Equal)
                }
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            })
            .then_with(|| rhs.item.item_copy_count().cmp(&lhs.item.item_copy_count()))
            .then_with(|| rhs.item.item_created_at().cmp(&lhs.item.item_created_at()))
    }

    fn merge_search_hits<T: SearchSortable>(
        raw_hits: Vec<SearchHit<T>>,
        pinyin_hits: Vec<SearchHit<T>>,
    ) -> Vec<T> {
        let mut merged: Vec<SearchHit<T>> = Vec::with_capacity(raw_hits.len() + pinyin_hits.len());
        let mut index_by_id = std::collections::HashMap::<String, usize>::new();

        for hit in raw_hits.into_iter().chain(pinyin_hits) {
            let id = hit.item.item_id().to_string();
            if let Some(index) = index_by_id.get(&id).copied() {
                if merged[index].raw_rank.is_none() && hit.raw_rank.is_some() {
                    merged[index].raw_rank = hit.raw_rank;
                }
                continue;
            }
            index_by_id.insert(id, merged.len());
            merged.push(hit);
        }

        merged.sort_by(Self::compare_search_hits);
        merged.into_iter().take(200).map(|hit| hit.item).collect()
    }

    fn query_raw_item_hits(
        conn: &Connection,
        search: &SearchQuery,
        type_filter: Option<&ClipType>,
    ) -> rusqlite::Result<Vec<SearchHit<ClipItem>>> {
        if search.raw.chars().count() >= 3 {
            let sql = if type_filter.is_some() {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count,
                        clip_fts.rank
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            } else {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count,
                        clip_fts.rank
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(
                    params![&search.raw_fts, t.as_str()],
                    Self::row_to_item_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(params![&search.raw_fts], Self::row_to_item_search_hit)?
                    .collect()
            }
        } else {
            let sql = if type_filter.is_some() {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\')
                   AND clip_type = ?2
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
            } else {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\'
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(
                    params![&search.raw_like, t.as_str()],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(
                    params![&search.raw_like],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            }
        }
    }

    fn query_pinyin_item_hits(
        conn: &Connection,
        normalized_pinyin: &str,
        type_filter: Option<&ClipType>,
    ) -> rusqlite::Result<Vec<SearchHit<ClipItem>>> {
        if normalized_pinyin.chars().count() >= 3 {
            let pinyin_fts = Self::build_fts5_query_for_columns(
                normalized_pinyin,
                &["pinyin_flat", "pinyin_initials"],
            );
            let sql = if type_filter.is_some() {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count,
                        NULL
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            } else {
                "SELECT ci.id, ci.content, ci.clip_type, ci.source_app, ci.source_name,
                        ci.is_pinned, ci.created_at, ci.image_path, ci.char_count, ci.copy_count, ci.first_copied_at, ci.ocr_text, ci.paste_count,
                        NULL
                 FROM clip_items ci
                 JOIN clip_fts ON clip_fts.rowid = ci.rowid
                 WHERE clip_fts MATCH ?1
                 ORDER BY ci.is_pinned DESC, ci.paste_count DESC, ci.copy_count DESC, ci.created_at DESC
                 LIMIT 200"
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(
                    params![pinyin_fts, t.as_str()],
                    Self::row_to_item_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(params![pinyin_fts], Self::row_to_item_search_hit)?
                    .collect()
            }
        } else {
            let pattern = Self::escape_like_pattern(normalized_pinyin);
            let sql = if type_filter.is_some() {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE (pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\')
                   AND clip_type = ?2
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
            } else {
                "SELECT id, content, clip_type, source_app, source_name,
                        is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count
                 FROM clip_items
                 WHERE pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\'
                 ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                 LIMIT 200"
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(
                    params![pattern, t.as_str()],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(sql)?;
                stmt.query_map(params![pattern], Self::row_to_item_search_hit_without_rank)?
                    .collect()
            }
        }
    }

    fn query_raw_list_hits(
        conn: &Connection,
        search: &SearchQuery,
        type_filter: Option<&ClipType>,
    ) -> rusqlite::Result<Vec<SearchHit<ClipListItem>>> {
        if search.raw.chars().count() >= 3 {
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count,
                            clip_fts.rank
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
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count,
                            clip_fts.rank
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, clip_fts.rank, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
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
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE (content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\')
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
                     WHERE content LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
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
    }

    fn query_pinyin_list_hits(
        conn: &Connection,
        normalized_pinyin: &str,
        type_filter: Option<&ClipType>,
    ) -> rusqlite::Result<Vec<SearchHit<ClipListItem>>> {
        if normalized_pinyin.chars().count() >= 3 {
            let pinyin_fts = Self::build_fts5_query_for_columns(
                normalized_pinyin,
                &["pinyin_flat", "pinyin_initials"],
            );
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count,
                            NULL
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1 AND ci.clip_type = ?2
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            } else {
                format!(
                    "SELECT ci.id, substr(COALESCE(NULLIF(ci.ocr_text,''),ci.content),1,{p}),
                            ci.clip_type, ci.source_app, ci.source_name, ci.is_pinned,
                            ci.created_at, ci.image_path, ci.char_count, ci.paste_count, ci.copy_count,
                            NULL
                     FROM clip_items ci
                     JOIN clip_fts ON clip_fts.rowid = ci.rowid
                     WHERE clip_fts MATCH ?1
                     ORDER BY ci.is_pinned DESC, ci.paste_count DESC, ci.copy_count DESC, ci.created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![pinyin_fts, t.as_str()],
                    Self::row_to_list_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(params![pinyin_fts], Self::row_to_list_search_hit)?
                    .collect()
            }
        } else {
            let pattern = Self::escape_like_pattern(normalized_pinyin);
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT id, substr(COALESCE(NULLIF(ocr_text,''),content),1,{p}),
                            clip_type, source_app, source_name, is_pinned,
                            created_at, image_path, char_count, paste_count, copy_count
                     FROM clip_items
                     WHERE (pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\')
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
                     WHERE pinyin_flat LIKE ?1 ESCAPE '\\' OR pinyin_initials LIKE ?1 ESCAPE '\\'
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200",
                    p = Self::LIST_PREVIEW_CHARS
                )
            };

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![pattern, t.as_str()],
                    Self::row_to_list_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(params![pattern], Self::row_to_list_search_hit_without_rank)?
                    .collect()
            }
        }
    }

    pub fn search(&self, query: &str, type_filter: Option<&ClipType>) -> Vec<ClipItem> {
        let conn = self.conn();
        let search = Self::build_search_query(query);
        let raw_hits = Self::query_raw_item_hits(&conn, &search, type_filter).unwrap_or_default();
        let pinyin_hits = search
            .normalized_pinyin
            .as_deref()
            .map(|normalized| {
                Self::query_pinyin_item_hits(&conn, normalized, type_filter).unwrap_or_default()
            })
            .unwrap_or_default();

        Self::merge_search_hits(raw_hits, pinyin_hits)
    }

    pub fn search_list_items(
        &self,
        query: &str,
        type_filter: Option<&ClipType>,
    ) -> Vec<ClipListItem> {
        let conn = self.conn();
        let search = Self::build_search_query(query);
        let raw_hits = Self::query_raw_list_hits(&conn, &search, type_filter).unwrap_or_default();
        let pinyin_hits = search
            .normalized_pinyin
            .as_deref()
            .map(|normalized| {
                Self::query_pinyin_list_hits(&conn, normalized, type_filter).unwrap_or_default()
            })
            .unwrap_or_default();

        Self::merge_search_hits(raw_hits, pinyin_hits)
    }

    pub fn get_item(&self, id: &str) -> Result<ClipItem, ClipinError> {
        let conn = self.conn();
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
        let conn = self.conn();
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
        let conn = self.conn();
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
        let conn = self.conn();
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
        let conn = self.conn();
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
        let conn = self.conn();
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
        // 锁外提前计算（同 save_item 的理由）
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count() as i32;
        let (pinyin_flat, pinyin_initials) = compute_pinyin(content);
        let mut conn = self.conn();
        let old_image_paths = Self::load_image_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

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

    /// 导入一条记录；若同 hash 已存在则跳过，保留现有条目的使用信号和 pin 状态。
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
        let mut conn = self.conn();

        if let Some(existing_id) = Self::load_item_id_for_hash(&conn, &hash)? {
            if clip_type == &ClipType::Image {
                if let Some(restored_path) = image_path {
                    let old_image_paths = Self::load_image_paths_for_hash(&conn, &hash)?;
                    let has_existing_image_file =
                        old_image_paths.iter().any(|path| Path::new(path).exists());

                    if !has_existing_image_file {
                        conn.execute(
                            "UPDATE clip_items SET image_path = ?1 WHERE id = ?2",
                            params![restored_path, existing_id],
                        )?;
                        Self::remove_image_files(old_image_paths, Some(restored_path));
                        return Ok(true);
                    }
                }
            }

            // 现有条目 reps 为空时补齐——计为 imported；reps 非空保留不覆盖
            if !representations.is_empty() {
                let existing_count: i32 = conn.query_row(
                    "SELECT COUNT(*) FROM clip_representations WHERE item_id = ?1",
                    params![existing_id],
                    |r| r.get(0),
                )?;
                if existing_count == 0 {
                    // 补齐副表必须与「现有条目仍为空」的判断在同一事务内，
                    // 否则并发导入同 hash 时两个调用都读到 0、各写一遍、互相覆盖。
                    let tx = conn.transaction()?;
                    for rep in representations {
                        tx.execute(
                            "INSERT OR REPLACE INTO clip_representations (item_id, uti, data) VALUES (?1, ?2, ?3)",
                            params![existing_id, rep.uti, rep.data],
                        )?;
                    }
                    tx.commit()?;
                    return Ok(true);
                }
            }
            return Ok(false);
        }

        // 主表 + 副表必须原子：旧实现 INSERT clip_items 后释放锁再单独写副表，
        // 进程在两步之间中断会留下「有 item 无 rep」的部分导入。
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,?7,?11,?12)",
            params![
                id,
                content,
                clip_type.as_str(),
                source_app,
                source_name,
                is_pinned as i32,
                created_at,
                image_path,
                char_count,
                hash,
                pinyin_flat,
                pinyin_initials,
            ],
        )?;
        for rep in representations {
            tx.execute(
                "INSERT OR REPLACE INTO clip_representations (item_id, uti, data) VALUES (?1, ?2, ?3)",
                params![id, rep.uti, rep.data],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }

    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        let conn = self.conn();
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
        let conn = self.conn();
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
        let conn = self.conn();
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

    fn row_to_item_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipItem>> {
        Ok(SearchHit {
            item: Self::row_to_item(row)?,
            raw_rank: row.get(13)?,
        })
    }

    fn row_to_item_search_hit_without_rank(
        row: &rusqlite::Row,
    ) -> rusqlite::Result<SearchHit<ClipItem>> {
        Ok(SearchHit {
            item: Self::row_to_item(row)?,
            raw_rank: None,
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

    fn row_to_list_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            raw_rank: row.get(11)?,
        })
    }

    fn row_to_list_search_hit_without_rank(
        row: &rusqlite::Row,
    ) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            raw_rank: None,
        })
    }

    pub fn increment_paste_count(&self, id: &str) -> Result<(), ClipinError> {
        let conn = self.conn();
        conn.execute(
            "UPDATE clip_items SET paste_count = paste_count + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// 读取某条目的全部副表 representation，按 uti 字典序返回。
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
}

impl SearchSortable for ClipItem {
    fn item_id(&self) -> &str {
        &self.id
    }
    fn item_is_pinned(&self) -> bool {
        self.is_pinned
    }
    fn item_paste_count(&self) -> i32 {
        self.paste_count
    }
    fn item_copy_count(&self) -> i32 {
        self.copy_count
    }
    fn item_created_at(&self) -> i64 {
        self.created_at
    }
}

impl SearchSortable for ClipListItem {
    fn item_id(&self) -> &str {
        &self.id
    }
    fn item_is_pinned(&self) -> bool {
        self.is_pinned
    }
    fn item_paste_count(&self) -> i32 {
        self.paste_count
    }
    fn item_copy_count(&self) -> i32 {
        self.copy_count
    }
    fn item_created_at(&self) -> i64 {
        self.created_at
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
        assert_eq!(storage.schema_version(), 9, "新建数据库应为 v9");
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
        assert_eq!(storage.schema_version(), 9, "旧数据库应 migrate 到 v9");

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
        assert_eq!(s2.schema_version(), 9);
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
        assert!(trigger_sql.contains(
            "AFTER UPDATE OF content, source_name, ocr_text, pinyin_flat, pinyin_initials"
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
}
