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

    /// FTS5 全文搜索
    pub fn search(&self, query: String, type_filter: Option<ClipType>) -> Vec<ClipItem> {
        self.storage.search(&query, type_filter.as_ref())
    }

    /// 切换 Pin 状态，返回新状态
    pub fn toggle_pin(&self, id: String) -> Result<bool, ClipinError> {
        self.storage.toggle_pin(&id)
    }

    /// 删除一条记录
    pub fn delete_item(&self, id: String) -> Result<(), ClipinError> {
        self.storage.delete_item(&id)
    }

    /// 清理指定时间戳之前的未 pin 记录，返回清理数量
    pub fn clear_unpinned_before(&self, timestamp: i64) -> Result<i32, ClipinError> {
        self.storage.clear_unpinned_before(timestamp)
    }

    /// 获取图片存储目录
    pub fn image_dir(&self) -> String {
        self.storage.image_dir().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn setup_core() -> Arc<ClipinCore> {
        let tmp = tempfile::tempdir().unwrap();
        let db_path = tmp.path().join("test.db");
        let img_dir = tmp.path().join("images");
        fs::create_dir_all(&img_dir).unwrap();

        // 泄漏 tmp 防止清理（测试用）
        let db = db_path.to_string_lossy().to_string();
        let img = img_dir.to_string_lossy().to_string();
        std::mem::forget(tmp);

        ClipinCore::new(db, img).unwrap()
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
    fn test_search() {
        let core = setup_core();

        core.save_item("rust programming language".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("swift ui tutorial".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("rust cargo build".into(), ClipType::Text, None, None, None)
            .unwrap();

        let results = core.search("rust".into(), None);
        assert_eq!(results.len(), 2);
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
}
