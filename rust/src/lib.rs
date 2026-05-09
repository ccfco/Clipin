mod models;
mod storage;

use models::*;
use std::sync::Arc;

uniffi::setup_scaffolding!();

/// Clipin 核心引擎，管理剪贴板历史的存储和搜索
#[derive(uniffi::Object)]
pub struct ClipinCore {
    storage: storage::Storage,
}

#[uniffi::export]
impl ClipinCore {
    /// 创建新的 ClipinCore 实例
    #[uniffi::constructor]
    pub fn new(db_path: String, image_dir: String) -> Result<Arc<Self>, ClipinError> {
        let storage = storage::Storage::new(&db_path, &image_dir)?;
        Ok(Arc::new(ClipinCore { storage }))
    }

    /// 保存一条剪贴板记录（自动去重）
    pub fn save_item(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
    ) -> Result<ClipItem, ClipinError> {
        self.storage.save_item(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
        )
    }

    /// 获取历史记录（分页，可按类型过滤）
    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Vec<ClipItem> {
        self.storage.get_items(limit, offset, type_filter.as_ref())
    }

    /// 获取导出专用快照。一次性读取稳定顺序，避免 OFFSET 分页期间历史变化导致跳项/重复。
    pub fn export_items_snapshot(&self) -> Vec<ClipItem> {
        self.storage.export_items_snapshot()
    }

    /// 获取轻量列表项，避免大文本拖慢列表渲染
    pub fn get_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Vec<ClipListItem> {
        self.storage
            .get_list_items(limit, offset, type_filter.as_ref())
    }

    /// 获取只包含 pinned 的轻量列表项，避免前端过滤污染分页 offset
    pub fn get_pinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Vec<ClipListItem> {
        self.storage
            .get_pinned_list_items(limit, offset, type_filter.as_ref())
    }

    /// 获取只包含未 pinned 的轻量列表项，避免 pinned-only 展示策略下第一页被隐藏项吃满
    pub fn get_unpinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Vec<ClipListItem> {
        self.storage
            .get_unpinned_list_items(limit, offset, type_filter.as_ref())
    }

    /// 搜索历史记录
    pub fn search(&self, query: String, type_filter: Option<ClipType>) -> Vec<ClipItem> {
        self.storage.search(&query, type_filter.as_ref())
    }

    /// 搜索轻量列表项
    pub fn search_list_items(
        &self,
        query: String,
        type_filter: Option<ClipType>,
    ) -> Vec<ClipListItem> {
        self.storage.search_list_items(&query, type_filter.as_ref())
    }

    /// 按 ID 获取完整记录，用于右侧详情预览
    pub fn get_item(&self, id: String) -> Result<ClipItem, ClipinError> {
        self.storage.get_item(&id)
    }

    /// 切换 Pin 状态，返回新状态
    pub fn toggle_pin(&self, id: String) -> Result<bool, ClipinError> {
        self.storage.toggle_pin(&id)
    }

    /// 删除一条记录
    pub fn delete_item(&self, id: String) -> Result<(), ClipinError> {
        self.storage.delete_item(&id)
    }

    /// 更新条目的时间戳，使其浮到列表顶部（粘贴时调用）
    pub fn touch_item(&self, id: String) -> Result<(), ClipinError> {
        self.storage.touch_item(&id)
    }

    /// 导入一条记录（保留原始时间戳和 pin 状态，用于跨设备迁移）
    pub fn import_item(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        is_pinned: bool,
        created_at: i64,
    ) -> Result<ClipItem, ClipinError> {
        self.storage.import_item(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            is_pinned,
            created_at,
        )
    }

    /// 导入一条记录；若同内容已存在则跳过，不重置现有条目的使用信号
    pub fn import_item_if_missing(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        is_pinned: bool,
        created_at: i64,
    ) -> Result<bool, ClipinError> {
        self.storage.import_item_if_missing(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            is_pinned,
            created_at,
        )
    }

    /// 清理指定时间戳之前的未 pin 记录，返回清理数量
    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        self.storage.clear_unpinned_before(timestamp)
    }

    /// 保留最新 N 条未 pin 记录，其余删除
    pub fn trim_unpinned(&self, keep_latest: i32) -> Result<i32, ClipinError> {
        self.storage.trim_unpinned(keep_latest)
    }

    /// 写入 OCR 识别结果（图片保存后异步调用）
    pub fn update_ocr_text(&self, id: String, ocr_text: String) -> Result<(), ClipinError> {
        self.storage.update_ocr_text(&id, &ocr_text)
    }

    /// 获取 OCR 尚未处理的图片条目（ocr_text IS NULL），用于 backfill
    pub fn get_unprocessed_images(&self, limit: i32) -> Vec<ClipItem> {
        self.storage.get_unprocessed_images(limit)
    }

    /// 粘贴时调用：paste_count +1，作为首要搜索排序信号
    pub fn increment_paste_count(&self, id: String) -> Result<(), ClipinError> {
        self.storage.increment_paste_count(&id)
    }

    /// 获取图片存储目录
    pub fn image_dir(&self) -> String {
        self.storage.image_dir().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf};

    fn setup_core_with_image_dir() -> (Arc<ClipinCore>, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test.db");
        let img_dir = tmp.path().join("images");
        fs::create_dir_all(&img_dir).unwrap();

        // 泄漏 tmp 防止清理（测试用）
        let db = db_path.to_string_lossy().to_string();
        let img = img_dir.to_string_lossy().to_string();
        std::mem::forget(tmp);

        (ClipinCore::new(db, img).unwrap(), img_dir)
    }

    fn setup_core() -> Arc<ClipinCore> {
        setup_core_with_image_dir().0
    }

    fn write_image(dir: &PathBuf, name: &str, bytes: &[u8]) -> String {
        let path = dir.join(name);
        fs::write(&path, bytes).unwrap();
        path.to_string_lossy().to_string()
    }

    #[test]
    fn test_save_and_get() {
        let core = setup_core();

        let item = core
            .save_item(
                "hello world".into(),
                ClipType::Text,
                Some("com.apple.Safari".into()),
                Some("Safari".into()),
                None,
            )
            .unwrap();

        assert_eq!(item.content, "hello world");
        assert_eq!(item.clip_type, ClipType::Text);
        assert_eq!(item.char_count, 11);

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content, "hello world");
    }

    #[test]
    fn test_dedup() {
        let core = setup_core();

        core.save_item("same".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("same".into(), ClipType::Text, None, None, None)
            .unwrap();

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 1, "重复内容应该去重");
    }

    #[test]
    fn test_pin() {
        let core = setup_core();

        let item = core
            .save_item("pin me".into(), ClipType::Text, None, None, None)
            .unwrap();
        assert!(!item.is_pinned);

        let pinned = core.toggle_pin(item.id.clone()).unwrap();
        assert!(pinned);

        let unpinned = core.toggle_pin(item.id).unwrap();
        assert!(!unpinned);
    }

    #[test]
    fn test_delete() {
        let core = setup_core();

        let item = core
            .save_item("delete me".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.delete_item(item.id).unwrap();

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 0);
    }

    #[test]
    fn test_type_filter() {
        let core = setup_core();

        core.save_item("text".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("url".into(), ClipType::Url, None, None, None)
            .unwrap();

        let text_only = core.get_items(10, 0, Some(ClipType::Text));
        assert_eq!(text_only.len(), 1);
        assert_eq!(text_only[0].content, "text");

        let url_only = core.get_items(10, 0, Some(ClipType::Url));
        assert_eq!(url_only.len(), 1);
        assert_eq!(url_only[0].content, "url");
    }

    #[test]
    fn test_list_items_are_truncated() {
        let core = setup_core();
        let content = "a".repeat(600);

        core.save_item(content.clone(), ClipType::Text, None, None, None)
            .unwrap();

        let items = core.get_list_items(10, 0, None);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].preview.len(), 240);

        let full_item = core.get_item(items[0].id.clone()).unwrap();
        assert_eq!(full_item.content, content);
    }

    #[test]
    fn test_search() {
        let core = setup_core();

        core.save_item(
            "rust programming language".into(),
            ClipType::Text,
            None,
            None,
            None,
        )
        .unwrap();
        core.save_item("swift ui tutorial".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("rust cargo build".into(), ClipType::Text, None, None, None)
            .unwrap();

        let results = core.search("rust".into(), None);
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_search_matches_pinyin_flat_and_initials() {
        let core = setup_core();

        core.save_item("你好世界".into(), ClipType::Text, None, None, None)
            .unwrap();

        let flat = core.search("nihao".into(), None);
        assert_eq!(flat.len(), 1);
        assert_eq!(flat[0].content, "你好世界");

        let initials = core.search("nh".into(), None);
        assert_eq!(initials.len(), 1);
        assert_eq!(initials[0].content, "你好世界");
    }

    #[test]
    fn test_search_matches_spaced_ime_pinyin_and_keeps_hot_item_first() {
        let core = setup_core();

        let hot = core
            .save_item("注意：高频条目".into(), ClipType::Text, None, None, None)
            .unwrap();
        let cold = core
            .save_item("注意：低频条目".into(), ClipType::Text, None, None, None)
            .unwrap();

        for _ in 0..10 {
            core.increment_paste_count(hot.id.clone()).unwrap();
        }
        core.increment_paste_count(cold.id).unwrap();

        let results = core.search("zhu yi".into(), None);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].content, "注意：高频条目");
        assert_eq!(results[0].paste_count, 10);

        let list_results = core.search_list_items("zhu yi".into(), None);
        assert_eq!(list_results.len(), 2);
        assert_eq!(list_results[0].preview, "注意：高频条目");
        assert_eq!(list_results[0].paste_count, 10);
    }

    #[test]
    fn test_search_ranks_candidates_before_limit() {
        let core = setup_core();

        for index in 0..240 {
            core.save_item(
                format!("common searchable cold item {index}"),
                ClipType::Text,
                None,
                None,
                None,
            )
            .unwrap();
        }
        let hot = core
            .save_item(
                "common searchable hot item".into(),
                ClipType::Text,
                None,
                None,
                None,
            )
            .unwrap();
        for _ in 0..50 {
            core.increment_paste_count(hot.id.clone()).unwrap();
        }

        let results = core.search("common searchable".into(), None);
        assert_eq!(results[0].content, "common searchable hot item");
        assert_eq!(results[0].paste_count, 50);

        let list_results = core.search_list_items("common searchable".into(), None);
        assert_eq!(list_results[0].preview, "common searchable hot item");
        assert_eq!(list_results[0].paste_count, 50);
    }

    #[test]
    fn test_export_items_snapshot_returns_stable_full_order() {
        let core = setup_core();
        let base = 1_700_000_000_000;

        let older = core
            .import_item(
                "older".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                base,
            )
            .unwrap();
        let newest = core
            .import_item(
                "newest".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                base + 1,
            )
            .unwrap();
        let tied = core
            .import_item(
                "same timestamp".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                base + 1,
            )
            .unwrap();
        let pinned = core
            .import_item(
                "pinned".into(),
                ClipType::Text,
                None,
                None,
                None,
                true,
                base - 1,
            )
            .unwrap();

        let mut expected_unpinned = vec![newest, tied, older];
        expected_unpinned.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| right.id.cmp(&left.id))
        });

        let snapshot = core.export_items_snapshot();
        let expected: Vec<String> = std::iter::once(pinned.content)
            .chain(expected_unpinned.into_iter().map(|item| item.content))
            .collect();
        let actual: Vec<String> = snapshot.into_iter().map(|item| item.content).collect();

        assert_eq!(actual, expected);
    }

    #[test]
    fn test_search_like_metachar_escaping() {
        let core = setup_core();

        // 保存含 LIKE 元字符的内容
        core.save_item("100% done".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("file_name.txt".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("hello world".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 搜 "%" 应只匹配 "100% done"，不匹配所有记录
        let pct = core.search("%".into(), None);
        assert_eq!(pct.len(), 1, "% 应作为字面量搜索，不匹配所有记录");
        assert_eq!(pct[0].content, "100% done");

        // 搜 "_" 应只匹配 "file_name.txt"，不匹配单字符通配
        let underscore = core.search("_".into(), None);
        assert_eq!(underscore.len(), 1, "_ 应作为字面量搜索，不匹配任意单字符");
        assert_eq!(underscore[0].content, "file_name.txt");
    }

    #[test]
    fn test_clear_old() {
        let core = setup_core();

        core.save_item("old".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("new".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 清理未来时间戳之前的所有记录
        let future = chrono::Utc::now().timestamp_millis() + 100_000;
        let cleared = core.clear_unpinned_before(future).unwrap();
        assert_eq!(cleared, 2);

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 0);
    }

    #[test]
    fn test_pinned_items_preserved_on_clear() {
        let core = setup_core();

        let item = core
            .save_item("pinned".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.toggle_pin(item.id).unwrap();

        core.save_item("not pinned".into(), ClipType::Text, None, None, None)
            .unwrap();

        let future = chrono::Utc::now().timestamp_millis() + 100_000;
        let cleared = core.clear_unpinned_before(future).unwrap();
        assert_eq!(cleared, 1);

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].content, "pinned");
    }

    #[test]
    fn test_image_dedup_uses_image_contents() {
        let (core, img_dir) = setup_core_with_image_dir();
        let first_path = write_image(&img_dir, "first.png", b"same-image-data");
        let second_path = write_image(&img_dir, "second.png", b"same-image-data");

        core.save_item(
            "image".into(),
            ClipType::Image,
            None,
            None,
            Some(first_path.clone()),
        )
        .unwrap();
        core.save_item(
            "image".into(),
            ClipType::Image,
            None,
            None,
            Some(second_path.clone()),
        )
        .unwrap();

        let items = core.get_items(10, 0, Some(ClipType::Image));
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].copy_count, 2);
        assert_eq!(items[0].image_path.as_deref(), Some(second_path.as_str()));
        assert!(!PathBuf::from(first_path).exists());
        assert!(PathBuf::from(second_path).exists());
    }

    #[test]
    fn test_dedup_preserves_paste_count() {
        let core = setup_core();

        let first = core
            .save_item("same".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.increment_paste_count(first.id.clone()).unwrap();
        core.increment_paste_count(first.id).unwrap();

        core.save_item("same".into(), ClipType::Text, None, None, None)
            .unwrap();

        let items = core.get_items(10, 0, None);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].copy_count, 2);
        assert_eq!(items[0].paste_count, 2);
    }

    #[test]
    fn test_import_distinct_images_do_not_collide() {
        let (core, img_dir) = setup_core_with_image_dir();
        let first_path = write_image(&img_dir, "import-1.png", b"image-one");
        let second_path = write_image(&img_dir, "import-2.png", b"image-two");

        core.import_item(
            "image".into(),
            ClipType::Image,
            None,
            None,
            Some(first_path),
            false,
            1_000,
        )
        .unwrap();
        core.import_item(
            "image".into(),
            ClipType::Image,
            None,
            None,
            Some(second_path),
            false,
            2_000,
        )
        .unwrap();

        let items = core.get_items(10, 0, Some(ClipType::Image));
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn test_import_item_if_missing_skips_duplicate_without_resetting_usage() {
        let core = setup_core();
        let existing = core
            .save_item("same".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.increment_paste_count(existing.id.clone()).unwrap();

        let imported = core
            .import_item_if_missing(
                "same".into(),
                ClipType::Text,
                Some("com.example.archive".into()),
                Some("Archive".into()),
                None,
                true,
                1_000,
            )
            .unwrap();

        let items = core.get_items(10, 0, None);
        assert!(!imported);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, existing.id);
        assert_eq!(items[0].paste_count, 1);
        assert!(!items[0].is_pinned);
    }

    #[test]
    fn test_import_item_if_missing_repairs_duplicate_image_with_missing_file() {
        let (core, img_dir) = setup_core_with_image_dir();
        let old_path = write_image(&img_dir, "missing.png", b"repair-image");
        let existing = core
            .import_item(
                "image".into(),
                ClipType::Image,
                None,
                None,
                Some(old_path.clone()),
                false,
                1_000,
            )
            .unwrap();
        core.increment_paste_count(existing.id.clone()).unwrap();
        fs::remove_file(&old_path).unwrap();

        let restored_path = write_image(&img_dir, "restored.png", b"repair-image");
        let repaired = core
            .import_item_if_missing(
                "image".into(),
                ClipType::Image,
                Some("com.example.archive".into()),
                Some("Archive".into()),
                Some(restored_path.clone()),
                true,
                2_000,
            )
            .unwrap();

        let items = core.get_items(10, 0, Some(ClipType::Image));
        assert!(repaired);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, existing.id);
        assert_eq!(items[0].paste_count, 1);
        assert!(!items[0].is_pinned);
        assert_eq!(items[0].image_path.as_deref(), Some(restored_path.as_str()));
        assert!(PathBuf::from(restored_path).exists());
    }

    #[test]
    fn test_delete_item_removes_image_file() {
        let (core, img_dir) = setup_core_with_image_dir();
        let image_path = write_image(&img_dir, "delete-me.png", b"delete-me");

        let item = core
            .save_item(
                "image".into(),
                ClipType::Image,
                None,
                None,
                Some(image_path.clone()),
            )
            .unwrap();

        core.delete_item(item.id).unwrap();

        assert!(!PathBuf::from(image_path).exists());
    }
}
