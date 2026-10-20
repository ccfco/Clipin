//! 读取路径：浏览分页、单条读取、列投影与 row 解码。
use super::Storage;
use super::search::SearchHit;
use crate::models::*;
use rusqlite::params;
use std::collections::HashMap;

impl Storage {
    /// ClipListItem 的 preview 截断长度（list_item_cols 的 substr 参数）。
    pub(super) const LIST_PREVIEW_CHARS: i32 = 240;

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
                 ORDER BY is_pinned DESC, created_at DESC, id DESC
                 LIMIT ?2 OFFSET ?3",
                Self::item_cols("")
            );
            let mut stmt = conn.prepare(&sql)?;
            let rows = stmt.query_map(params![filter_val, limit, offset], Self::row_to_item)?;
            Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
        } else {
            let sql = format!(
                "SELECT {} FROM clip_items
                 ORDER BY is_pinned DESC, created_at DESC, id DESC
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
                     ORDER BY is_pinned DESC, created_at DESC, id DESC
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
                     ORDER BY is_pinned DESC, created_at DESC, id DESC
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
                     ORDER BY is_pinned DESC, created_at DESC, id DESC
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
                     ORDER BY is_pinned DESC, created_at DESC, id DESC
                     LIMIT ?1 OFFSET ?2",
                    cols = Self::list_item_cols("")
                );
                let mut stmt = conn.prepare(&sql)?;
                let rows = stmt.query_map(params![limit, offset], Self::row_to_list_item)?;
                Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
            }
        }
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

    /// 语义标签 backfill 专用：ai_tags IS NULL（未处理）且文本足够生成标签的条目。
    /// 图片要等 OCR 完成（ocr_text 非 NULL）才进入候选，否则只能拿 "image" 占位文案。
    /// 无标签的条目写入空串而非留在 NULL，避免每轮 backfill 反复扫到同一批。
    pub fn get_untagged_items(&self, limit: i32) -> Result<Vec<ClipItem>, ClipinError> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {} FROM clip_items
             WHERE ai_tags IS NULL
               AND (
                   (clip_type != 'image' AND length(trim(content)) >= 8)
                   OR (clip_type = 'image' AND ocr_text IS NOT NULL AND length(trim(ocr_text)) >= 8)
               )
             ORDER BY created_at ASC
             LIMIT ?1",
            Self::item_cols("")
        ))?;
        let rows = stmt.query_map(params![limit], Self::row_to_item)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// ClipItem 的 16 列投影,顺序必须与 row_to_item 的 ordinal 0..=15 一一对应。
    /// 改列顺序 = 同步改本函数 + row_to_item 两处,别处不再手抄。
    /// prefix: "" (裸列:浏览/LIKE/get_item) 或 "ci." (JOIN clip_fts 时消歧)。
    /// FTS 分支的 `, clip_fts.rank` 由调用点自行 format! 追加,不在此函数内。
    pub(super) fn item_cols(prefix: &str) -> String {
        [
            "id", "content", "clip_type", "source_app", "source_name",
            "is_pinned", "created_at", "image_path", "char_count", "copy_count",
            "first_copied_at", "ocr_text", "paste_count", "alias", "attachment_paths",
            "ai_tags",
        ]
        .iter()
        .map(|c| format!("{prefix}{c}"))
        .collect::<Vec<_>>()
        .join(", ")
    }

    /// ClipListItem 的 15 列投影(第二列是 preview 表达式,吃 LIST_PREVIEW_CHARS),
    /// 顺序必须与 row_to_list_item 的 ordinal 0..=14 一一对应。
    /// 改列顺序 = 同步改本函数 + row_to_list_item 两处。prefix 与 rank 约定同 item_cols。
    pub(super) fn list_item_cols(prefix: &str) -> String {
        let p = Self::LIST_PREVIEW_CHARS;
        format!(
            "{prefix}id, \
             substr(COALESCE(NULLIF({prefix}ocr_text,''),{prefix}content),1,{p}), \
             {prefix}clip_type, {prefix}source_app, {prefix}source_name, {prefix}is_pinned, \
             {prefix}created_at, {prefix}image_path, {prefix}char_count, {prefix}paste_count, {prefix}copy_count, \
             {prefix}image_width, {prefix}image_height, {prefix}alias, {prefix}attachment_paths"
        )
    }

    /// ClipItem 行解码:ordinal 0..=15 必须与 item_cols 的列顺序逐位对应。
    /// 改列顺序只动 item_cols + 本函数两处,各 SELECT 全由 item_cols 派生不再手抄。
    pub(super) fn row_to_item(row: &rusqlite::Row) -> rusqlite::Result<ClipItem> {
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
            ai_tags: row.get(15)?,
        })
    }

    pub(super) fn row_to_item_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipItem>> {
        Ok(SearchHit {
            item: Self::row_to_item(row)?,
            // item 投影占 0..=15，FTS rank 永远追加在数据列之后。
            raw_rank: row.get(16)?,
        })
    }

    pub(super) fn row_to_item_search_hit_without_rank(
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
    pub(super) fn row_to_list_item(row: &rusqlite::Row) -> rusqlite::Result<ClipListItem> {
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

    pub(super) fn row_to_list_search_hit(row: &rusqlite::Row) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            // image_width/image_height 占 11、12，alias 占 13，attachment_paths 占 14，FTS rank 后移到 15
            raw_rank: row.get(15)?,
        })
    }

    pub(super) fn row_to_list_search_hit_without_rank(
        row: &rusqlite::Row,
    ) -> rusqlite::Result<SearchHit<ClipListItem>> {
        Ok(SearchHit {
            item: Self::row_to_list_item(row)?,
            raw_rank: None,
        })
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
