//! 搜索：FTS5（≥3 字）与 LIKE 回退（≤2 字）、拼音匹配，候选在 SQL 层排序后 LIMIT。
use super::Storage;
use crate::models::*;
use rusqlite::{Connection, params};

#[derive(Clone, Debug)]
struct SearchQuery {
    raw: String,
    raw_fts: String,
    raw_like: String,
    normalized_pinyin: Option<String>,
}

#[derive(Clone, Debug)]
pub(super) struct SearchHit<T: SearchSortable> {
    pub(super) item: T,
    pub(super) raw_rank: Option<f64>,
}

pub(super) trait SearchSortable: Clone {
    fn item_id(&self) -> &str;
    fn item_is_pinned(&self) -> bool;
    fn item_paste_count(&self) -> i32;
    fn item_copy_count(&self) -> i32;
    fn item_created_at(&self) -> i64;
}

impl Storage {
    /// 可搜索文本列的唯一真相源：FTS 查询（≥3 字）与 LIKE 回退（≤2 字）都从这里
    /// 派生，保证两条路径匹配语义一致。加搜索列只改这一处（FTS 表结构/触发器
    /// 与 migration 仍需单独同步）。曾因 LIKE 分支手写 4 份列清单漂移漏掉
    /// source_name，收口后此类漂移结构性消除。
    const SEARCHABLE_TEXT_COLS: &'static [&'static str] =
        &["content", "source_name", "ocr_text", "alias"];

    fn build_search_query(query: &str) -> SearchQuery {
        let raw = query.trim().to_string();
        SearchQuery {
            raw_fts: Self::build_fts5_query_for_columns(&raw, Self::SEARCHABLE_TEXT_COLS),
            raw_like: Self::escape_like_pattern(&raw),
            normalized_pinyin: Self::normalize_pinyin_query(&raw),
            raw,
        }
    }

    /// 转义 FTS5 phrase query，内部的 " 翻倍。
    fn escape_fts5_phrase(query: &str) -> String {
        format!("\"{}\"", query.replace('"', "\"\""))
    }

    /// LIKE 回退分支的 WHERE 片段，列清单来自 SEARCHABLE_TEXT_COLS。
    /// ?1 由调用点绑定 raw_like（escape_like_pattern 已转义 % _ \）。
    fn like_where_clause() -> String {
        Self::SEARCHABLE_TEXT_COLS
            .iter()
            .map(|column| format!("{column} LIKE ?1 ESCAPE '\\'"))
            .collect::<Vec<_>>()
            .join(" OR ")
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
            let like_where = Self::like_where_clause();
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE ({like_where})
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE {like_where}
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
            let like_where = Self::like_where_clause();
            let sql = if type_filter.is_some() {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE ({like_where})
                       AND clip_type = ?2
                     ORDER BY is_pinned DESC, paste_count DESC, copy_count DESC, created_at DESC
                     LIMIT 200"
                )
            } else {
                format!(
                    "SELECT {cols}
                     FROM clip_items
                     WHERE {like_where}
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
