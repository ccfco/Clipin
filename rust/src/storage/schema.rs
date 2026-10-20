//! schema 初始化与版本化迁移（v1..v12）。已发布的 migration 函数冻结，只追加新版本。
use super::Storage;
use crate::models::*;
use pinyin::ToPinyin;
use rusqlite::{Connection, params};

/// 把文本中的 CJK 字符转为拼音（无声调）：
///
/// - flat: 所有音节连续拼接，例如 "你好" → "nihao"
/// - initials: 每个音节首字母，例如 "你好" → "nh"
///
/// 非 CJK 字符直接跳过，只处理前 500 个字符（性能保障）。
pub(super) fn compute_pinyin(content: &str) -> (String, String) {
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

impl Storage {
    pub(super) fn init_schema(&self) -> Result<(), ClipinError> {
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
}
