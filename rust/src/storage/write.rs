//! 写入路径：保存去重、导入、编辑、pin、计数与按时间/数量清理。
use super::Storage;
use super::media::PreservedItemState;
use super::schema::compute_pinyin;
use crate::models::*;
use rusqlite::params;
use std::path::Path;
use uuid::Uuid;

impl Storage {
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
                ocr_text: existing.ocr_text,
                ai_tags: existing.ai_tags,
            },
            None => PreservedItemState {
                first_copied_at: now,
                copy_count: 1,
                paste_count: 0,
                is_pinned: false,
                alias: None,
                ocr_text: None,
                ai_tags: None,
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
             (id,content,clip_type,source_app,source_name,is_pinned,created_at,image_path,char_count,hash,copy_count,first_copied_at,paste_count,pinyin_flat,pinyin_initials,alias,attachment_paths,ocr_text,ai_tags)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)",
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
                preserved.ocr_text.as_deref(),
                preserved.ai_tags.as_deref(),
            ],
        )?;
        Self::insert_representations_in_tx(&tx, &id, representations)?;
        tx.commit()?;
        // commit 后必须先释放连接锁再删文件：fs::remove_file 是磁盘 I/O，
        // 持锁期间主线程的 getListItems/search 全部排队，批量场景会卡 UI。
        drop(conn);
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
            ocr_text: preserved.ocr_text,
            paste_count: preserved.paste_count,
            alias: preserved.alias,
            ai_tags: preserved.ai_tags,
        })
    }

    pub fn update_ocr_text(&self, id: &str, ocr_text: &str) -> Result<(), ClipinError> {
        let conn = self.conn();
        // OCR 是标签的输入之一：重写识别结果必须让旧标签失效，由 backfill 重新生成。
        let affected = conn.execute(
            "UPDATE clip_items SET ocr_text = ?1, ai_tags = NULL WHERE id = ?2",
            params![ocr_text, id],
        )?;
        if affected == 0 {
            return Err(ClipinError::NotFound { id: id.to_string() });
        }
        Ok(())
    }

    /// 写入 Apple Intelligence 语义标签。空串表示「已处理但无可用标签」，
    /// 与 NULL（未处理）区分，防止 backfill 对同一批无标签条目无限重跑。
    pub fn update_ai_tags(&self, id: &str, ai_tags: &str) -> Result<(), ClipinError> {
        let conn = self.conn();
        let affected = conn.execute(
            "UPDATE clip_items SET ai_tags = ?1 WHERE id = ?2",
            params![ai_tags, id],
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
        // 别名参与标签输入：改名后旧标签失效，由 backfill 重新生成。
        conn.execute(
            "UPDATE clip_items
             SET alias = ?1, pinyin_flat = ?2, pinyin_initials = ?3, ai_tags = NULL
             WHERE id = ?4",
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
            // 内容变了，旧语义标签必然失效：置 NULL 让 backfill 重新生成，
            // 否则搜索会继续命中已不存在于内容里的旧标签。
            "UPDATE clip_items
             SET content = ?1, clip_type = ?2, hash = ?3, char_count = ?4,
                 pinyin_flat = ?5, pinyin_initials = ?6, ai_tags = NULL
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
        drop(conn); // 释放锁再删文件（同 save 路径，避免文件 I/O 持锁阻塞查询）
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
        drop(conn); // 释放锁再删文件（同 save 路径）
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
            ai_tags: None,
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
                        drop(conn); // 释放锁再删文件（同 save 路径）
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
        drop(conn); // 批量清理可删成百上千 PNG，必须先释放锁（同 save 路径）
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
        drop(conn); // 批量清理可删成百上千 PNG，必须先释放锁（同 save 路径）
        if affected > 0 {
            Self::remove_image_files(image_paths, None);
        }
        Ok(affected as i32)
    }

    pub fn increment_paste_count(&self, id: &str) -> Result<(), ClipinError> {
        let conn = self.conn();
        conn.execute(
            "UPDATE clip_items SET paste_count = paste_count + 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }
}
