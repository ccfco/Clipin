//! 媒体文件与去重：内容 hash、附件路径解析、图片落盘与孤儿清理。
use super::Storage;
use crate::models::*;
use rusqlite::{Connection, params};
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::ErrorKind,
    path::Path,
};

#[derive(Clone, Debug)]
pub(super) struct PreservedItemState {
    pub(super) first_copied_at: i64,
    pub(super) copy_count: i32,
    pub(super) paste_count: i32,
    pub(super) is_pinned: bool,
    pub(super) alias: Option<String>,
    /// 同一 hash 的重新复制（图片 OCR 完成后再次复制同一张图）必须保留识别结果：
    /// OCR 是异步的，用户很可能在识别完成前后重复复制同一张图；丢掉 ocr_text
    /// 会让新条目搜不到图片里的文字，直到下次启动 backfill 才补回来。
    pub(super) ocr_text: Option<String>,
    /// 语义标签是 content/OCR 的派生结果，同 hash 重新复制时原样保留。
    pub(super) ai_tags: Option<String>,
}

impl Storage {
    pub(super) fn content_hash(content: &str, clip_type: &ClipType) -> String {
        let mut hasher = Sha256::new();
        hasher.update(clip_type.as_str().as_bytes());
        hasher.update(b":");
        hasher.update(content.as_bytes());
        format!("{:x}", hasher.finalize())
    }

    pub(super) fn content_hash_bytes(bytes: &[u8], clip_type: &ClipType) -> String {
        let mut hasher = Sha256::new();
        hasher.update(clip_type.as_str().as_bytes());
        hasher.update(b":");
        hasher.update(bytes);
        format!("{:x}", hasher.finalize())
    }

    pub(super) fn hash_for_item(
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

    pub(super) fn load_media_paths_for_hash(
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

    pub(super) fn load_item_id_for_hash(conn: &Connection, hash: &str) -> Result<Option<String>, ClipinError> {
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

    pub(super) fn load_media_paths_for_item(conn: &Connection, id: &str) -> Result<Vec<String>, ClipinError> {
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

    pub(super) fn load_preserved_item_state_for_hash(
        conn: &Connection,
        hash: &str,
    ) -> Result<Option<PreservedItemState>, ClipinError> {
        conn.query_row(
            "SELECT first_copied_at, copy_count, paste_count, is_pinned, alias, ocr_text, ai_tags
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
                    ocr_text: row.get(5)?,
                    ai_tags: row.get(6)?,
                })
            },
        )
        .map(Some)
        .or_else(|err| match err {
            rusqlite::Error::QueryReturnedNoRows => Ok(None),
            other => Err(other.into()),
        })
    }

    pub(super) fn load_media_paths_before(
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

    pub(super) fn load_trimmed_media_paths(
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

    pub(super) fn remove_image_files(paths: Vec<String>, keep_path: Option<&str>) {
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
            // 只处理 image_dir 顶层的图片文件（不递归子目录）。图片可能保留
            // 原始编码（jpg/heic/heif），不能只扫 png，否则这些孤儿永远不会被回收。
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .map(|s| s.to_ascii_lowercase());
            if !matches!(
                ext.as_deref(),
                Some("png" | "jpg" | "jpeg" | "heic" | "heif" | "tiff" | "tif")
            ) {
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
}
