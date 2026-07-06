use crate::models::*;
use pinyin::ToPinyin;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::ErrorKind,
    path::Path,
    sync::{Mutex, MutexGuard},
};
use uuid::Uuid;

/// 把文本中的 CJK 字符转为拼音（无声调）：
///
/// - flat: 所有音节连续拼接，例如 "你好" → "nihao"
/// - initials: 每个音节首字母，例如 "你好" → "nh"
///
/// 非 CJK 字符直接跳过，只处理前 500 个字符（性能保障）。
fn compute_pinyin(content: &str) -> (String, String) {
    let limited: String = content.chars().take(500).collect();
    let mut flat = String::new();
    let mut initials = String::new();
    for py in (&*limited).to_pinyin().flatten() {
        let syllable: &str = py.plain();
        flat.push_str(syllable);
        if let Some(c) = syllable.chars().next() {
            initials.push(c);
        }
    }
    (flat, initials)
}

pub struct Storage {
    conn: Mutex<Connection>,
    image_dir: String,
}

#[derive(Clone, Debug)]
struct PreservedItemState {
    first_copied_at: i64,
    copy_count: i32,
    paste_count: i32,
    is_pinned: bool,
    alias: Option<String>,
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
                &["content", "source_name", "ocr_text", "alias"],
            ),
            raw_like: Self::escape_like_pattern(&raw),
            normalized_pinyin: Self::normalize_pinyin_query(&raw),
            raw,
        }
    }

    pub fn new(db_path: &str, image_dir: &str) -> Result<Self, ClipinError> {
        let conn = Connection::open(db_path)?;
        // WAL：写不阻塞读、fsync 只对 -wal 文件，剪贴板的「高频小写」场景代价显著降低
        // synchronous=NORMAL：依靠 WAL checkpoint 保证持久性，单进程语义足够，崩溃最坏丢最近几条
        // foreign_keys=ON：保留既有约束
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;",
        )?;
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
        if from_version < 10 {
            Self::migrate_to_v10(&self.conn())?;
        }
        if from_version < 11 {
            Self::migrate_to_v11(&self.conn())?;
        }
        if from_version < 12 {
            Self::migrate_to_v12(&self.conn())?;
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

    fn migrate_to_v10(conn: &Connection) -> Result<(), ClipinError> {
        // 图片像素尺寸列：仅 image 类型有值，采集时与历史 backfill 异步写入。
        // 可空 INTEGER：NULL = 尚未测量（backfill 据此定位），ADD COLUMN 不重写表。
        //
        // SQLite 的 ADD COLUMN 不支持 IF NOT EXISTS，且每条 ALTER 各自 autocommit——
        // 若第一条 ALTER 已提交、user_version 还没推进时进程崩溃，下次重进 migrate_to_v10
        // 会因 duplicate column 永久失败。同 migrate_to_v6：用 PRAGMA table_info 逐列判存，
        // 缺哪列补哪列，保证整个迁移可重入。
        let existing: Vec<String> = conn
            .prepare("PRAGMA table_info(clip_items)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        if !existing.iter().any(|n| n == "image_width") {
            conn.execute_batch("ALTER TABLE clip_items ADD COLUMN image_width INTEGER;")?;
        }
        if !existing.iter().any(|n| n == "image_height") {
            conn.execute_batch("ALTER TABLE clip_items ADD COLUMN image_height INTEGER;")?;
        }
        conn.execute_batch("PRAGMA user_version = 10;")?;
        Ok(())
    }

    fn migrate_to_v11(conn: &Connection) -> Result<(), ClipinError> {
        // 用户别名列。可空：NULL 表示未命名，列表显示名回退到按类型推导的标题。
        // 幂等检查：崩溃重启重跑时不能重复 ALTER（同 migrate_to_v6/v10 套路）。
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

             PRAGMA user_version = 11;",
        )?;
        Ok(())
    }

    fn migrate_to_v12(conn: &Connection) -> Result<(), ClipinError> {
        // file 类型图片附件缓存路径。只存 JSON 路径数组，图片 bytes 仍落 image_dir 磁盘文件；
        // 追加列保证既有 row decoder ordinal 不重排，迁移可重入以覆盖 ALTER 后崩溃场景。
        let has_attachment_paths: bool = conn
            .prepare("PRAGMA table_info(clip_items)")?
            .query_map([], |row| row.get::<_, String>(1))?
            .any(|n| n.as_deref() == Ok("attachment_paths"));
        if !has_attachment_paths {
            conn.execute_batch("ALTER TABLE clip_items ADD COLUMN attachment_paths TEXT;")?;
        }
        conn.execute_batch("PRAGMA user_version = 12;")?;
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

    fn attachment_paths_from_json(raw: Option<String>) -> Vec<String> {
        let Some(raw) = raw else { return Vec::new() };
        let trimmed = raw.trim();
        if trimmed.len() < 2 || !trimmed.starts_with('[') || !trimmed.ends_with(']') {
            return Vec::new();
        }

        let mut paths = Vec::new();
        let mut chars = trimmed[1..trimmed.len() - 1].chars().peekable();
        while let Some(ch) = chars.next() {
            if ch != '"' {
                continue;
            }

            let mut value = String::new();
            while let Some(c) = chars.next() {
                match c {
                    '"' => {
                        if !value.is_empty() {
                            paths.push(value);
                        }
                        break;
                    }
                    '\\' => {
                        if let Some(escaped) = chars.next() {
                            match escaped {
                                '"' | '\\' | '/' => value.push(escaped),
                                'n' => value.push('\n'),
                                'r' => value.push('\r'),
                                't' => value.push('\t'),
                                'b' | 'f' => {}
                                other => value.push(other),
                            }
                        }
                    }
                    other => value.push(other),
                }
            }
        }
        paths
    }

    fn load_media_paths_for_hash(
        conn: &Connection,
        hash: &str,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path, attachment_paths FROM clip_items WHERE hash = ?1",
        )?;
        let rows = stmt.query_map(params![hash], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        })?;
        let mut paths = Vec::new();
        for row in rows {
            let (image_path, attachment_paths) = row?;
            if let Some(path) = image_path {
                paths.push(path);
            }
            paths.extend(Self::attachment_paths_from_json(attachment_paths));
        }
        Ok(paths)
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

    fn load_media_paths_for_item(conn: &Connection, id: &str) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path, attachment_paths FROM clip_items WHERE id = ?1",
        )?;
        let rows = stmt.query_map(params![id], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        })?;
        let mut paths = Vec::new();
        for row in rows {
            let (image_path, attachment_paths) = row?;
            if let Some(path) = image_path {
                paths.push(path);
            }
            paths.extend(Self::attachment_paths_from_json(attachment_paths));
        }
        Ok(paths)
    }

    fn load_preserved_item_state_for_hash(
        conn: &Connection,
        hash: &str,
    ) -> Result<Option<PreservedItemState>, ClipinError> {
        conn.query_row(
            "SELECT first_copied_at, copy_count, paste_count, is_pinned, alias
             FROM clip_items
             WHERE hash = ?1",
            params![hash],
            |row| {
                Ok(PreservedItemState {
                    first_copied_at: row.get(0)?,
                    copy_count: row.get(1)?,
                    // paste_count 是 NOT NULL DEFAULT 0，不可能为 NULL。用 ? 让解码
                    // 错误/列错位响亮失败，而非 unwrap_or(0) 静默吞成 0（CLAUDE.md「不兜底」）。
                    paste_count: row.get(2)?,
                    is_pinned: row.get(3)?,
                    alias: row.get(4)?,
                })
            },
        )
        .map(Some)
        .or_else(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other.into()),
        })
    }

    fn load_media_paths_before(
        conn: &Connection,
        timestamp: i64,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "SELECT image_path, attachment_paths
             FROM clip_items
             WHERE is_pinned = 0 AND created_at < ?1",
        )?;
        let rows = stmt.query_map(params![timestamp], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        })?;
        let mut paths = Vec::new();
        for row in rows {
            let (image_path, attachment_paths) = row?;
            if let Some(path) = image_path {
                paths.push(path);
            }
            paths.extend(Self::attachment_paths_from_json(attachment_paths));
        }
        Ok(paths)
    }

    fn load_trimmed_media_paths(
        conn: &Connection,
        keep_latest: i32,
    ) -> Result<Vec<String>, ClipinError> {
        let mut stmt = conn.prepare(
            "
            SELECT image_path, attachment_paths
            FROM clip_items
            WHERE is_pinned = 0
              AND id IN (
                  SELECT id
                  FROM clip_items
                  WHERE is_pinned = 0
                  ORDER BY created_at DESC
                  LIMIT -1 OFFSET ?1
              )
            ",
        )?;
        let rows = stmt.query_map(params![keep_latest], |row| {
            Ok((
                row.get::<_, Option<String>>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        })?;
        let mut paths = Vec::new();
        for row in rows {
            let (image_path, attachment_paths) = row?;
            if let Some(path) = image_path {
                paths.push(path);
            }
            paths.extend(Self::attachment_paths_from_json(attachment_paths));
        }
        Ok(paths)
    }

    fn remove_image_files(paths: Vec<String>, keep_path: Option<&str>) {
        let keep_path = keep_path.map(str::to_string);
        let mut unique_paths = HashSet::new();

        for path in paths {
            if keep_path.as_deref() == Some(path.as_str()) || !unique_paths.insert(path.clone()) {
                continue;
            }

            if let Err(err) = fs::remove_file(&path)
                && err.kind() != ErrorKind::NotFound {
                    eprintln!("⚠️ Failed to remove image file {}: {}", path, err);
                }
        }
    }

    // ── CRUD ─────────────────────────────────────────────────────────────────

    pub fn save_item(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
    ) -> Result<ClipItem, ClipinError> {
        self.save_item_with_representations_and_id(
            None,
            content,
            clip_type,
            source_app,
            source_name,
            image_path,
            None,
            &[],
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn save_item_with_attachment_paths(
        &self,
        item_id: Option<&str>,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        attachment_paths: Option<&str>,
        representations: &[ClipRepresentation],
    ) -> Result<ClipItem, ClipinError> {
        self.save_item_with_representations_and_id(
            item_id,
            content,
            clip_type,
            source_app,
            source_name,
            image_path,
            attachment_paths,
            representations,
        )
    }

    /// 在调用方已持有的事务内写入 representations（`INSERT OR REPLACE`，按 uti 幂等）。
    /// 必须接收 `&Transaction` 而非 `&self`：`Storage::conn()` 不可重入，再取一次锁会
    /// 死锁；且 rep 与主表写入必须落在同一事务才能保证原子性。
    fn insert_representations_in_tx(
        tx: &rusqlite::Transaction,
        item_id: &str,
        representations: &[ClipRepresentation],
    ) -> Result<(), ClipinError> {
        for rep in representations {
            tx.execute(
                "INSERT OR REPLACE INTO clip_representations (item_id, uti, data) VALUES (?1, ?2, ?3)",
                params![item_id, rep.uti, rep.data],
            )?;
        }
        Ok(())
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
        self.save_item_with_representations_and_id(
            None,
            content,
            clip_type,
            source_app,
            source_name,
            image_path,
            None,
            representations,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn save_item_with_representations_and_id(
        &self,
        item_id: Option<&str>,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        attachment_paths: Option<&str>,
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
                alias: existing.alias,
            },
            None => PreservedItemState {
                first_copied_at: now,
                copy_count: 1,
                paste_count: 0,
                is_pinned: false,
                alias: None,
            },
        };

        // 重新复制带别名的条目时，别名要并入拼音（与 set_alias 口径一致）
        let (pinyin_flat, pinyin_initials) = match preserved.alias.as_deref() {
            Some(a) if !a.is_empty() => compute_pinyin(&format!("{content} {a}")),
            _ => (pinyin_flat, pinyin_initials),
        };

        let old_image_paths = Self::load_media_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        let id = item_id
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,paste_count,pinyin_flat,pinyin_initials,alias,attachment_paths)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
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
                preserved.alias,
                attachment_paths,
            ],
        )?;
        Self::insert_representations_in_tx(&tx, &id, representations)?;
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
            attachment_paths: attachment_paths.map(String::from),
            char_count,
            copy_count: preserved.copy_count,
            first_copied_at: preserved.first_copied_at,
            ocr_text: None,
            paste_count: preserved.paste_count,
            alias: preserved.alias,
        })
    }

    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipItem>, ClipinError> {
        let conn = self.conn();

        // 旧实现把 prepare/query_map/row decode 错误统一用 filter_map(.ok) + unwrap_or_default()
        // 吞掉——主列表浏览/分页路径任何失败都会被伪装成"历史为空"，违反 CLAUDE.md 「不兜底」。
        // 任何 SQL 失败或行解码失败都向上传播，Swift 层显式 notice。
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
    }

    /// 导出专用：在同一把锁内一次性读出 items 与各自的 representations。
    /// 旧实现先快照 items 再逐条 `load_representations` 二次取锁，两次之间条目可能
    /// 被删除/CASCADE，导致导出的 v2 archive 丢 representations。
    /// items 顺序固定为 is_pinned DESC, created_at DESC, id DESC（导入/分页依赖此稳定序）。
    pub fn export_archive_snapshot(&self) -> Result<Vec<ArchiveSnapshotItem>, ClipinError> {
        let conn = self.conn();
        let items: Vec<ClipItem> = {
            let mut stmt = conn.prepare(&format!(
                "SELECT {} FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC, id DESC",
                Self::item_cols("")
            ))?;
            let rows = stmt.query_map([], Self::row_to_item)?;
            // 旧实现 filter_map(.ok) 会让单行 decode 失败被静默丢弃，归档仍然显示"成功"
            // 但快照实际少条目；按 "不兜底" 改为 fail-fast，便于在备份阶段就发现 schema 漂移。
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };

        // 一次拉全部 representations，按 item_id 在内存里分组，避免「持 mutex 的 N+1」
        // 旧实现是循环里每条 item 跑一次 prepared query，万条历史 = 万次 prepare/exec，
        // 全程持锁会把主线程的 getListItems 卡住几秒到几十秒（备份大库时直接感知卡顿）。
        let mut reps_by_item: HashMap<String, Vec<ClipRepresentation>> = HashMap::new();
        {
            let mut stmt = conn.prepare(
                "SELECT item_id, uti, data FROM clip_representations ORDER BY item_id, uti",
            )?;
            let rows = stmt.query_map([], |row| {
                let item_id: String = row.get(0)?;
                Ok((
                    item_id,
                    ClipRepresentation {
                        uti: row.get(1)?,
                        data: row.get(2)?,
                    },
                ))
            })?;
            for row in rows {
                let (item_id, rep) = row?;
                reps_by_item.entry(item_id).or_default().push(rep);
            }
        }

        let result = items
            .into_iter()
            .map(|item| {
                let representations = reps_by_item.remove(&item.id).unwrap_or_default();
                ArchiveSnapshotItem {
                    item,
                    representations,
                }
            })
            .collect();
        Ok(result)
    }

    // ── Browse & Search ───────────────────────────────────────────────────────

    pub fn get_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, None)
    }

    pub fn get_pinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, Some(true))
    }

    pub fn get_unpinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.get_list_items_with_pinned_filter(limit, offset, type_filter, Some(false))
    }

    fn get_list_items_with_pinned_filter(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<&ClipType>,
        pinned_filter: Option<bool>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        let conn = self.conn();

        // 旧实现整段 and_then(...).unwrap_or_default()，主列表浏览/分页路径任何 SQL/decode
        // 失败都被伪装成"空列表"，分页 sentinel 也可能误判 hasMore——按 "不兜底" 改 Result，
        // Swift fetchBrowsePage 不再把 DB 故障当作"没有更多数据"。
        match (type_filter, pinned_filter) {
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
            (Some(t), None) => {
                let filter_val = t.as_str().to_string();
                let sql = format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE clip_type = ?1
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?2 OFFSET ?3",
                    cols = Self::list_item_cols("")
                );
                let mut stmt = conn.prepare(&sql)?;
                let rows =
                    stmt.query_map(params![filter_val, limit, offset], Self::row_to_list_item)?;
                Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
            }
            (None, Some(pinned)) => {
                let pinned_val = if pinned { 1 } else { 0 };
                let sql = format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE is_pinned = ?1
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?2 OFFSET ?3",
                    cols = Self::list_item_cols("")
                );
                let mut stmt = conn.prepare(&sql)?;
                let rows =
                    stmt.query_map(params![pinned_val, limit, offset], Self::row_to_list_item)?;
                Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
            }
            (None, None) => {
                let sql = format!(
                    "SELECT {cols}
                     FROM clip_items
                     ORDER BY is_pinned DESC, created_at DESC
                     LIMIT ?1 OFFSET ?2",
                    cols = Self::list_item_cols("")
                );
                let mut stmt = conn.prepare(&sql)?;
                let rows = stmt.query_map(params![limit, offset], Self::row_to_list_item)?;
                Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
            }
        }
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
                     WHERE (content LIKE ?1 ESCAPE '\\' OR source_name LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE content LIKE ?1 ESCAPE '\\' OR source_name LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\'
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
            // 拼音 FTS 路径原本把 rank 选成 NULL、ORDER BY 也漏掉 rank，
            // 导致拼音命中后排序退化为 (pin, paste, copy, time)，违反 CLAUDE.md
            // 「FTS 路径 ORDER BY 必须包含 clip_fts.rank」硬约束——同名查询走 raw FTS
            // 有 rank、拼音 FTS 没有，会造成两路 hit 合并后顺序不稳定。
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
                    params![pinyin_fts, t.as_str()],
                    Self::row_to_item_search_hit,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(params![pinyin_fts], Self::row_to_item_search_hit)?
                    .collect()
            }
        } else {
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

            if let Some(t) = type_filter {
                let mut stmt = conn.prepare(&sql)?;
                stmt.query_map(
                    params![pattern, t.as_str()],
                    Self::row_to_item_search_hit_without_rank,
                )?
                .collect()
            } else {
                let mut stmt = conn.prepare(&sql)?;
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
                     WHERE (content LIKE ?1 ESCAPE '\\' OR source_name LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\')
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE content LIKE ?1 ESCAPE '\\' OR source_name LIKE ?1 ESCAPE '\\' OR ocr_text LIKE ?1 ESCAPE '\\' OR alias LIKE ?1 ESCAPE '\\'
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
            // 同 query_pinyin_item_hits：rank 必须从 clip_fts.rank 取，
            // ORDER BY 同步补 clip_fts.rank，跟 raw FTS list 路径保持一致排序语义。
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

    // ── Full-text search ──────────────────────────────────────────────────────

    pub fn search(
        &self,
        query: &str,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipItem>, ClipinError> {
        let conn = self.conn();
        let search = Self::build_search_query(query);
        // 旧实现两路都 unwrap_or_default() 会把 SQL/FTS 故障伪装成"没有匹配项"——
        // 用户搜索没结果时根本无法分辨"真的没有"和"DB 坏了"。按 CLAUDE.md "不兜底"
        // 约束，任一路 SQL 失败都向上传播，Swift 层显式 surface notice。
        let raw_hits = Self::query_raw_item_hits(&conn, &search, type_filter)?;
        let pinyin_hits = match search.normalized_pinyin.as_deref() {
            Some(normalized) => Self::query_pinyin_item_hits(&conn, normalized, type_filter)?,
            None => Vec::new(),
        };
        Ok(Self::merge_search_hits(raw_hits, pinyin_hits))
    }

    pub fn search_list_items(
        &self,
        query: &str,
        type_filter: Option<&ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        let conn = self.conn();
        let search = Self::build_search_query(query);
        let raw_hits = Self::query_raw_list_hits(&conn, &search, type_filter)?;
        let pinyin_hits = match search.normalized_pinyin.as_deref() {
            Some(normalized) => Self::query_pinyin_list_hits(&conn, normalized, type_filter)?,
            None => Vec::new(),
        };
        Ok(Self::merge_search_hits(raw_hits, pinyin_hits))
    }

    pub fn get_item(&self, id: &str) -> Result<ClipItem, ClipinError> {
        let conn = self.conn();
        conn.query_row(
            &format!(
                "SELECT {} FROM clip_items WHERE id = ?1",
                Self::item_cols("")
            ),
            params![id],
            Self::row_to_item,
        )
        .map_err(|_| ClipinError::NotFound {
            id: id.to_string(),
        })
    }

    /// OCR backfill 专用：直接查 ocr_text IS NULL，无需 offset，不受新增条目影响。
    /// 旧实现 filter_map(.ok) + unwrap_or_default 会让 SQL/decode 失败被静默吞掉，
    /// OCR backfill 长期"无声停止"——按 "不兜底" 改 Result，调用方 log 错误。
    pub fn get_unprocessed_images(&self, limit: i32) -> Result<Vec<ClipItem>, ClipinError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM clip_items
             WHERE clip_type = 'image' AND ocr_text IS NULL
             ORDER BY created_at ASC
             LIMIT ?1",
            Self::item_cols("")
        ))?;
        let rows = stmt.query_map(params![limit], Self::row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// 尺寸 backfill 专用：查 image_width IS NULL 的图片（含已 OCR 的历史条目）。
    /// 与 get_unprocessed_images 同构——直接查 NULL 列，无 offset，不受新增条目影响。
    pub fn get_unsized_images(&self, limit: i32) -> Result<Vec<ClipItem>, ClipinError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM clip_items
             WHERE clip_type = 'image' AND image_width IS NULL
             ORDER BY created_at ASC
             LIMIT ?1",
            Self::item_cols("")
        ))?;
        let rows = stmt.query_map(params![limit], Self::row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
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

    /// 写入图片像素尺寸（图片保存后 / backfill 时异步调用）。
    /// image_width / image_height 不在 FTS 触发器字段内，更新不会重写索引。
    pub fn update_image_dimensions(
        &self,
        id: &str,
        width: i32,
        height: i32,
    ) -> Result<(), ClipinError> {
        let conn = self.conn();
        let affected = conn.execute(
            "UPDATE clip_items SET image_width = ?1, image_height = ?2 WHERE id = ?3",
            params![width, height, id],
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
        let mut conn = self.conn();
        // SELECT image_path + DELETE 必须在同一事务里：当前是单连接 + Mutex 串行化，
        // 但「靠 Mutex 兜事务」是隐式契约，一旦未来加只读连接就会有「读到但已删」的窗口。
        // 用显式事务把契约写在代码里。文件删除仍放在 commit 之后。
        let tx = conn.transaction()?;
        let image_paths = Self::load_media_paths_for_item(&tx, id)?;
        let affected = tx.execute("DELETE FROM clip_items WHERE id = ?1", params![id])?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        tx.commit()?;
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

    // ── Import / Cleanup / Maintenance ───────────────────────────────────────

    /// 导入一条记录（保留原始 created_at 和 is_pinned）
    #[allow(clippy::too_many_arguments)]
    pub fn import_item(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        is_pinned: bool,
        created_at: i64,
        alias: Option<&str>,
    ) -> Result<ClipItem, ClipinError> {
        // 空字符串别名归一化为 None（与 set_alias 口径一致）
        let alias = alias.filter(|a| !a.is_empty());
        // 锁外提前计算（同 save_item 的理由）
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count() as i32;
        // 拼音并入别名，否则导入恢复出来的中文别名搜不到
        let pinyin_source = match alias {
            Some(a) => format!("{content} {a}"),
            None => content.to_string(),
        };
        let (pinyin_flat, pinyin_initials) = compute_pinyin(&pinyin_source);
        let mut conn = self.conn();
        let old_image_paths = Self::load_media_paths_for_hash(&conn, &hash)?;
        let tx = conn.transaction()?;
        tx.execute("DELETE FROM clip_items WHERE hash = ?1", params![hash])?;

        tx.execute(
            "INSERT INTO clip_items
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials,alias,attachment_paths)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,?7,?11,?12,?13,NULL)",
            params![
                id, content, clip_type.as_str(), source_app, source_name,
                is_pinned as i32, created_at, image_path, char_count, hash,
                pinyin_flat, pinyin_initials, alias,
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
            attachment_paths: None,
            char_count,
            copy_count: 1,
            first_copied_at: created_at,
            ocr_text: None,
            paste_count: 0,
            alias: alias.map(String::from),
        })
    }

    /// 导入一条记录；若同 hash 已存在则跳过，保留现有条目的使用信号和 pin 状态。
    #[allow(clippy::too_many_arguments)]
    pub fn import_item_if_missing(
        &self,
        content: &str,
        clip_type: &ClipType,
        source_app: Option<&str>,
        source_name: Option<&str>,
        image_path: Option<&str>,
        is_pinned: bool,
        created_at: i64,
        alias: Option<&str>,
        representations: &[ClipRepresentation],
    ) -> Result<bool, ClipinError> {
        // 空字符串别名归一化为 None（与 set_alias 口径一致）
        let alias = alias.filter(|a| !a.is_empty());
        let hash = Self::hash_for_item(content, clip_type, image_path)?;
        let id = Uuid::new_v4().to_string();
        let char_count = content.chars().count() as i32;
        // 拼音并入别名，否则导入恢复出来的中文别名搜不到
        let pinyin_source = match alias {
            Some(a) => format!("{content} {a}"),
            None => content.to_string(),
        };
        let (pinyin_flat, pinyin_initials) = compute_pinyin(&pinyin_source);
        let mut conn = self.conn();

        if let Some(existing_id) = Self::load_item_id_for_hash(&conn, &hash)? {
            if clip_type == &ClipType::Image
                && let Some(restored_path) = image_path {
                    let old_image_paths = Self::load_media_paths_for_hash(&conn, &hash)?;
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

            // 现有条目 alias 为空、备份带别名时补上，计为 imported。
            // 补别名必须同步重算拼音（入参 content + alias），与 set_alias 口径一致——
            // 否则导入恢复出来的中文别名搜不到。content 取本次入参即可：同 hash ⟹ 同 content。
            // 注意：不能改调 self.set_alias()，它内部会再次 self.conn() 取锁，与此处
            // 已持有的 conn 形成 std::Mutex 重入死锁。必须就地 UPDATE。
            if let Some(new_alias) = alias.filter(|a| !a.is_empty()) {
                let existing_alias: Option<String> = conn.query_row(
                    "SELECT alias FROM clip_items WHERE id = ?1",
                    params![existing_id],
                    |r| r.get(0),
                )?;
                if existing_alias.as_deref().unwrap_or("").is_empty() {
                    let (alias_pinyin_flat, alias_pinyin_initials) =
                        compute_pinyin(&format!("{content} {new_alias}"));
                    conn.execute(
                        "UPDATE clip_items
                         SET alias = ?1, pinyin_flat = ?2, pinyin_initials = ?3
                         WHERE id = ?4",
                        params![new_alias, alias_pinyin_flat, alias_pinyin_initials, existing_id],
                    )?;
                    return Ok(true);
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
                    Self::insert_representations_in_tx(&tx, &existing_id, representations)?;
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
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,pinyin_flat,pinyin_initials,alias,attachment_paths)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,1,?7,?11,?12,?13,NULL)",
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
                alias,
            ],
        )?;
        Self::insert_representations_in_tx(&tx, &id, representations)?;
        tx.commit()?;
        Ok(true)
    }

    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        let mut conn = self.conn();
        // 同 delete_item：SELECT image_path + DELETE 用事务包裹，commit 后再删文件
        let tx = conn.transaction()?;
        let image_paths = Self::load_media_paths_before(&tx, timestamp)?;
        let affected = tx.execute(
            "DELETE FROM clip_items WHERE is_pinned = 0 AND created_at < ?1",
            params![timestamp],
        )?;
        tx.commit()?;
        if affected > 0 {
            Self::remove_image_files(image_paths, None);
        }
        Ok(affected as i32)
    }

    /// 保留最新 N 条未 pin 记录，其余删除
    pub fn trim_unpinned(&self, keep_latest: i32) -> Result<i32, ClipinError> {
        let mut conn = self.conn();
        let keep_latest = keep_latest.max(0);
        // 同 delete_item：SELECT image_path + DELETE 用事务包裹，commit 后再删文件
        let tx = conn.transaction()?;
        let image_paths = Self::load_trimmed_media_paths(&tx, keep_latest)?;
        let affected = tx.execute(
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
        tx.commit()?;
        if affected > 0 {
            Self::remove_image_files(image_paths, None);
        }
        Ok(affected as i32)
    }

    /// 扫 image_dir 找未被任何 clip_items 引用的 PNG，删掉。
    /// 引用源 = image_path 列 + attachment_paths JSON 数组（解析后展开）。
    ///
    /// 防误删：只删 mtime 早于 (now - max_age_seconds) 的文件——保护正在采集
    /// 还未入库的 PNG（典型 race：PNG 已写 → 用户立刻触发 reconcile → DB save 未到）。
    /// 启动时调用一次清理上次崩溃/异常终止留下的孤儿——R1 修复（Codex review）。
    /// 调用方在启动时 detach 跑，避免阻塞 main actor。
    pub fn reconcile_orphan_attachments(
        &self,
        max_age_seconds: i64,
    ) -> Result<i32, ClipinError> {
        let conn = self.conn();
        let mut referenced: HashSet<String> = HashSet::new();
        {
            let mut stmt = conn.prepare(
                "SELECT image_path, attachment_paths FROM clip_items"
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            })?;
            for row in rows {
                let (image_path, attachment_paths) = row?;
                if let Some(p) = image_path {
                    if !p.is_empty() { referenced.insert(p); }
                }
                for p in Self::attachment_paths_from_json(attachment_paths) {
                    if !p.is_empty() { referenced.insert(p); }
                }
            }
        }
        drop(conn);  // 让 query 提早释放锁，扫盘期间不持有 DB 连接

        let entries = match fs::read_dir(&self.image_dir) {
            Ok(e) => e,
            // image_dir 不存在 = 还没有任何图片采集过 = 没有孤儿可清
            Err(_) => return Ok(0),
        };
        let max_age = max_age_seconds.max(0) as u64;
        let cutoff = std::time::SystemTime::now()
            .checked_sub(std::time::Duration::from_secs(max_age));
        let mut removed = 0;
        for entry in entries.flatten() {
            let path = entry.path();
            // 只处理 image_dir 顶层的 PNG（不递归子目录）
            if path.extension().and_then(|s| s.to_str()) != Some("png") {
                continue;
            }
            let path_str = path.to_string_lossy().into_owned();
            if referenced.contains(&path_str) { continue; }
            // mtime 保护：太新的文件可能正在 in-flight 采集
            if let (Some(cutoff), Ok(meta)) = (cutoff, entry.metadata()) {
                if let Ok(modified) = meta.modified() {
                    if modified > cutoff { continue; }
                }
            }
            if fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }

    pub fn write_attachment_png(
        &self,
        item_id: &str,
        index: i32,
        bytes: &[u8],
    ) -> Result<String, ClipinError> {
        fs::create_dir_all(&self.image_dir)?;
        let filename = format!("{item_id}_{index}.png");
        let path = Path::new(&self.image_dir).join(filename);
        fs::write(&path, bytes)?;
        Ok(path.to_string_lossy().to_string())
    }

    pub fn image_dir(&self) -> &str {
        &self.image_dir
    }

    /// 当前 schema 版本号，用于验证 migration 已正确执行
    #[cfg(test)]
    pub fn schema_version(&self) -> i32 {
        let conn = self.conn();
        // PRAGMA user_version 必返回一行整数；查询失败说明 DB 句柄异常，测试里应响亮
        // 失败而非 unwrap_or(0) 伪装成"版本 0"误导 migration 断言。
        conn.query_row("PRAGMA user_version", [], |r| r.get(0))
            .expect("PRAGMA user_version query failed")
    }

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

    /// ClipItem 行解码:ordinal 0..=14 必须与 item_cols 的列顺序逐位对应。
    /// 改列顺序只动 item_cols + 本函数两处,各 SELECT 全由 item_cols 派生不再手抄。
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
            // NOT NULL DEFAULT 0，用 ? 而非 unwrap_or(0)：列错位时立刻报错不静默兜底。
            paste_count: row.get(12)?,
            alias: row.get(13)?,
            attachment_paths: row.get(14)?,
        })
    }

    fn row_to_item_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipItem>> {
        Ok(SearchHit {
            item: Self::row_to_item(row)?,
            raw_rank: row.get(15)?,
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

    /// ClipListItem 行解码:ordinal 0..=14 必须与 list_item_cols 的列顺序逐位对应
    /// (注意与 item_cols 顺序不同:此处 paste_count 在 copy_count 之前)。
    /// 改列顺序只动 list_item_cols + 本函数两处。FTS rank 固定在 ordinal 15。
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
            // paste_count/copy_count 均 NOT NULL（DEFAULT 0 / 1），用 ? 让列错位响亮失败，
            // 不用 unwrap_or 静默兜底——否则解码到错误字段会被伪装成合法的 0/1（CLAUDE.md「不兜底」）。
            paste_count: row.get(9)?,
            copy_count: row.get(10)?,
            image_width: row.get(11)?,
            image_height: row.get(12)?,
            alias: row.get(13)?,
            attachment_paths: row.get(14)?,
        })
    }

    fn row_to_list_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            // image_width/image_height 占 11、12，alias 占 13，attachment_paths 占 14，FTS rank 后移到 15
            raw_rank: row.get(15)?,
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

    /// 只读某条目的 representation UTI 列表，不触碰 data BLOB。
    /// 选中导航高频调用：图片的 data 是无压缩 TIFF/PNG（数十 MB），若为拿格式名而读全部 data
    /// 并跨 UniFFI 拷贝，会让「上下选中大图」付出加载全部格式数据的代价（卡顿根因）。
    /// 选中只需知道「有哪些格式」，data 留到真正「粘贴为该格式」时按需读。
    pub fn load_representation_utis(&self, item_id: &str) -> Result<Vec<String>, ClipinError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT uti FROM clip_representations WHERE item_id = ?1 ORDER BY uti",
        )?;
        let rows = stmt.query_map(params![item_id], |row| row.get(0))?;
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
#[path = "storage_tests.rs"]
mod migration_tests;
