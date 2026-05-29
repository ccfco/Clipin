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

    /// 保存剪贴板记录并写入 representations。当 representations 为空时等价于 save_item。
    pub fn save_item_with_representations(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        representations: Vec<ClipRepresentation>,
    ) -> Result<ClipItem, ClipinError> {
        self.storage.save_item_with_representations(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            &representations,
        )
    }

    /// 保存带磁盘附件缓存路径的剪贴板记录。item_id 由调用方先生成，用于先写
    /// <item_id>_<index>.png，再以同一个 id 入库。
    #[allow(clippy::too_many_arguments)]
    pub fn save_item_with_attachment_paths(
        &self,
        item_id: String,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        attachment_paths: Option<String>,
        representations: Vec<ClipRepresentation>,
    ) -> Result<ClipItem, ClipinError> {
        self.storage.save_item_with_attachment_paths(
            Some(&item_id),
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            attachment_paths.as_deref(),
            &representations,
        )
    }

    /// 把图片附件 bytes 写入 imageDir，返回可持久化到 attachment_paths 的 PNG 路径。
    pub fn write_attachment_png(
        &self,
        item_id: String,
        index: i32,
        bytes: Vec<u8>,
    ) -> Result<String, ClipinError> {
        self.storage.write_attachment_png(&item_id, index, &bytes)
    }

    /// 扫 imageDir 清理无主 PNG（崩溃 / 异常终止留下的孤儿）。
    /// max_age_seconds：mtime 保护——只删早于该时长的文件，避免误删 in-flight 采集
    /// 还未入库的 PNG。启动时 detach 调用一次，返回清理数量。
    pub fn reconcile_orphan_attachments(
        &self,
        max_age_seconds: i64,
    ) -> Result<i32, ClipinError> {
        self.storage.reconcile_orphan_attachments(max_age_seconds)
    }

    /// 读取一条条目的所有 representations
    pub fn get_representations(
        &self,
        id: String,
    ) -> Result<Vec<ClipRepresentation>, ClipinError> {
        self.storage.load_representations(&id)
    }

    /// 导出专用快照，原子性见 `Storage::export_archive_snapshot`。
    pub fn export_archive_snapshot(&self) -> Result<Vec<ArchiveSnapshotItem>, ClipinError> {
        self.storage.export_archive_snapshot()
    }

    /// 获取轻量列表项，避免大文本拖慢列表渲染
    pub fn get_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.storage
            .get_list_items(limit, offset, type_filter.as_ref())
    }

    /// 获取只包含 pinned 的轻量列表项，避免前端过滤污染分页 offset
    pub fn get_pinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.storage
            .get_pinned_list_items(limit, offset, type_filter.as_ref())
    }

    /// 获取只包含未 pinned 的轻量列表项，避免 pinned-only 展示策略下第一页被隐藏项吃满
    pub fn get_unpinned_list_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
        self.storage
            .get_unpinned_list_items(limit, offset, type_filter.as_ref())
    }

    /// 搜索轻量列表项
    pub fn search_list_items(
        &self,
        query: String,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipListItem>, ClipinError> {
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

    /// 导入一条记录；若同内容已存在则跳过，不重置现有条目的使用信号
    #[allow(clippy::too_many_arguments)]
    pub fn import_item_if_missing(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        is_pinned: bool,
        created_at: i64,
        alias: Option<String>,
        representations: Vec<ClipRepresentation>,
    ) -> Result<bool, ClipinError> {
        self.storage.import_item_if_missing(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            is_pinned,
            created_at,
            alias.as_deref(),
            &representations,
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

    /// 写入或清空条目别名（空字符串视为清空）
    pub fn set_alias(&self, id: String, alias: Option<String>) -> Result<(), ClipinError> {
        self.storage.set_alias(&id, alias.as_deref())
    }

    /// 编辑条目真实内容（仅 text/url；类型由调用方依据新内容判定后传入）
    pub fn update_content(
        &self,
        id: String,
        new_content: String,
        new_type: ClipType,
    ) -> Result<(), ClipinError> {
        self.storage.update_content(&id, &new_content, &new_type)
    }

    /// 获取 OCR 尚未处理的图片条目（ocr_text IS NULL），用于 backfill
    pub fn get_unprocessed_images(&self, limit: i32) -> Result<Vec<ClipItem>, ClipinError> {
        self.storage.get_unprocessed_images(limit)
    }

    /// 写入图片像素尺寸（图片保存后异步调用）
    pub fn update_image_dimensions(
        &self,
        id: String,
        width: i32,
        height: i32,
    ) -> Result<(), ClipinError> {
        self.storage.update_image_dimensions(&id, width, height)
    }

    /// 获取尚未测量尺寸的图片条目（image_width IS NULL），用于 backfill
    pub fn get_unsized_images(&self, limit: i32) -> Result<Vec<ClipItem>, ClipinError> {
        self.storage.get_unsized_images(limit)
    }

    /// 粘贴时调用：paste_count +1，作为首要搜索排序信号
    pub fn increment_paste_count(&self, id: String) -> Result<(), ClipinError> {
        self.storage.increment_paste_count(&id)
    }

    /// 获取图片存储目录
    pub fn image_dir(&self) -> String {
        self.storage.image_dir().to_string()
    }

    /// 完整 item 分页查询。生产 Swift 路径不用（list 列表走 get_list_items），
    /// 但 ClipinTests 的 ArchiveServiceTests / ArchiveV2Tests 用它来 setup + assert
    /// 完整 ClipItem 字段（pasteCount/isPinned/imagePath 等 ClipListItem 不带的字段）。
    /// 这是合法测试消费者，必须留在 UniFFI binding 里。
    pub fn get_items(
        &self,
        limit: i32,
        offset: i32,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipItem>, ClipinError> {
        self.storage.get_items(limit, offset, type_filter.as_ref())
    }

    /// 完整 item 搜索。生产 Swift 路径只用 search_list_items，但保留以便测试使用。
    pub fn search(
        &self,
        query: String,
        type_filter: Option<ClipType>,
    ) -> Result<Vec<ClipItem>, ClipinError> {
        self.storage.search(&query, type_filter.as_ref())
    }

    /// 不带 if_missing 的 import。生产 Swift 路径走 import_item_if_missing
    /// （归档导入需要去重语义），但测试 setup 阶段需要无条件插入"已存在的条目"
    /// 来验证去重/修复行为，所以保留。
    #[allow(clippy::too_many_arguments)]
    pub fn import_item(
        &self,
        content: String,
        clip_type: ClipType,
        source_app: Option<String>,
        source_name: Option<String>,
        image_path: Option<String>,
        is_pinned: bool,
        created_at: i64,
        alias: Option<String>,
    ) -> Result<ClipItem, ClipinError> {
        self.storage.import_item(
            &content,
            &clip_type,
            source_app.as_deref(),
            source_name.as_deref(),
            image_path.as_deref(),
            is_pinned,
            created_at,
            alias.as_deref(),
        )
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
    fn test_new_item_has_no_alias() {
        let core = setup_core();
        let item = core
            .save_item("plain".into(), ClipType::Text, None, None, None)
            .unwrap();
        assert_eq!(item.alias, None, "新建条目别名应为 None");

        let fetched = core.get_item(item.id.clone()).unwrap();
        assert_eq!(fetched.alias, None, "get_item 读出的别名应为 None");
    }

    #[test]
    fn test_set_alias_writes_and_clears() {
        let core = setup_core();
        let item = core
            .save_item("body".into(), ClipType::Text, None, None, None)
            .unwrap();

        core.set_alias(item.id.clone(), Some("My Label".into())).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias.as_deref(), Some("My Label"));

        // 空字符串归一化为 NULL
        core.set_alias(item.id.clone(), Some("".into())).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias, None);

        // None 同样清空
        core.set_alias(item.id.clone(), Some("X".into())).unwrap();
        core.set_alias(item.id.clone(), None).unwrap();
        assert_eq!(core.get_item(item.id.clone()).unwrap().alias, None);
    }

    #[test]
    fn test_set_alias_chinese_is_searchable_by_pinyin() {
        let core = setup_core();
        let item = core
            .save_item("ghp_xxx".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("密钥".into())).unwrap();

        // 别名拼音全拼命中
        assert_eq!(core.search("miyao".into(), None).unwrap().len(), 1);
        // 别名拼音首字母命中
        assert_eq!(core.search("my".into(), None).unwrap().len(), 1);
    }

    #[test]
    fn test_set_alias_not_found() {
        let core = setup_core();
        let err = core.set_alias("no-such-id".into(), Some("X".into()));
        assert!(matches!(err, Err(ClipinError::NotFound { .. })));
    }

    #[test]
    fn test_search_matches_alias_text() {
        let core = setup_core();
        let item = core
            .save_item("ghp_abcdefghABCDEF".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("GitHub PAT".into())).unwrap();

        // 长查询走 FTS 路径
        assert_eq!(core.search("GitHub".into(), None).unwrap().len(), 1);
        assert_eq!(core.search_list_items("GitHub".into(), None).unwrap().len(), 1);
        // 短查询走 LIKE 路径
        assert_eq!(core.search("PA".into(), None).unwrap().len(), 1);
    }

    #[test]
    fn test_list_item_carries_alias() {
        let core = setup_core();
        let item = core
            .save_item("ghp_secret_token_value".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 未命名：list item alias 为 None，preview 为内容兜底
        let before = core.get_list_items(10, 0, None).unwrap();
        assert_eq!(before[0].alias, None);
        assert_eq!(before[0].preview, "ghp_secret_token_value");

        // 命名后：list item alias 有值；preview 仍是内容兜底
        // （"别名优先"的显示名逻辑在 Swift displayTitle，不在 SQL）
        core.set_alias(item.id.clone(), Some("GitHub PAT".into())).unwrap();
        let after = core.get_list_items(10, 0, None).unwrap();
        assert_eq!(after[0].alias.as_deref(), Some("GitHub PAT"));
        assert_eq!(after[0].preview, "ghp_secret_token_value");
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

        let items = core.get_items(10, 0, None).unwrap();
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

        let items = core.get_items(10, 0, None).unwrap();
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

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 0);
    }

    #[test]
    fn test_type_filter() {
        let core = setup_core();

        core.save_item("text".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.save_item("url".into(), ClipType::Url, None, None, None)
            .unwrap();

        let text_only = core.get_items(10, 0, Some(ClipType::Text)).unwrap();
        assert_eq!(text_only.len(), 1);
        assert_eq!(text_only[0].content, "text");

        let url_only = core.get_items(10, 0, Some(ClipType::Url)).unwrap();
        assert_eq!(url_only.len(), 1);
        assert_eq!(url_only[0].content, "url");
    }

    #[test]
    fn test_list_items_are_truncated() {
        let core = setup_core();
        let content = "a".repeat(600);

        core.save_item(content.clone(), ClipType::Text, None, None, None)
            .unwrap();

        let items = core.get_list_items(10, 0, None).unwrap();
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

        let results = core.search("rust".into(), None).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn test_search_matches_pinyin_flat_and_initials() {
        let core = setup_core();

        core.save_item("你好世界".into(), ClipType::Text, None, None, None)
            .unwrap();

        let flat = core.search("nihao".into(), None).unwrap();
        assert_eq!(flat.len(), 1);
        assert_eq!(flat[0].content, "你好世界");

        let initials = core.search("nh".into(), None).unwrap();
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

        let results = core.search("zhu yi".into(), None).unwrap();
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].content, "注意：高频条目");
        assert_eq!(results[0].paste_count, 10);

        let list_results = core.search_list_items("zhu yi".into(), None).unwrap();
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

        let results = core.search("common searchable".into(), None).unwrap();
        assert_eq!(results[0].content, "common searchable hot item");
        assert_eq!(results[0].paste_count, 50);

        let list_results = core.search_list_items("common searchable".into(), None).unwrap();
        assert_eq!(list_results[0].preview, "common searchable hot item");
        assert_eq!(list_results[0].paste_count, 50);
    }

    #[test]
    fn test_search_sort_priority_full_chain() {
        // 覆盖搜索排序完整优先级链 is_pinned > paste_count > copy_count > created_at。
        // 用 2 字符查询走 LIKE 路径（raw_rank=None），把"相关度"这一级摘掉后，剩下四级
        // 可用纯数据差异逐级隔离验证 SQL ORDER BY 与 compare_search_hits 的层级一致。
        // 补 keeps_hot_item_first / ranks_candidates_before_limit 未覆盖的两段：顶层
        // is_pinned 压制 paste_count、以及 copy_count 压制 created_at。
        let core = setup_core();

        // ① 已固定但零粘贴：is_pinned 必须压过下面 paste_count=5 的高频项
        let pinned = core
            .save_item("zq pinned".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.toggle_pin(pinned.id.clone()).unwrap();

        // ② 未固定 + paste_count=5：压过 copy_count / created_at
        let hot_paste = core
            .save_item("zq hot paste".into(), ClipType::Text, None, None, None)
            .unwrap();
        for _ in 0..5 {
            core.increment_paste_count(hot_paste.id.clone()).unwrap();
        }

        // ③ 未固定 + copy_count=4（同内容重复保存触发 dedup 累加），created_at 较旧：
        //    必须靠 copy_count 压过下面 created_at 更新的 ④
        for _ in 0..4 {
            core.save_item("zq hot copy".into(), ClipType::Text, None, None, None)
                .unwrap();
        }

        // ④ 未固定、copy=1、paste=0，但 created_at 最新：应排末位（输给 ③ 的 copy_count）
        core.save_item("zq newest".into(), ClipType::Text, None, None, None)
            .unwrap();

        let expected = [
            "zq pinned",    // is_pinned 最高优先
            "zq hot paste", // paste_count > copy_count / created_at
            "zq hot copy",  // copy_count > created_at
            "zq newest",    // 末位
        ];

        let results = core.search("zq".into(), None).unwrap();
        let order: Vec<&str> = results.iter().map(|i| i.content.as_str()).collect();
        assert_eq!(order, expected, "full ClipItem 搜索排序优先级链不符");

        let list_results = core.search_list_items("zq".into(), None).unwrap();
        let list_order: Vec<&str> = list_results.iter().map(|i| i.preview.as_str()).collect();
        assert_eq!(list_order, expected, "ClipListItem 搜索排序优先级链不符");
    }

    #[test]
    fn test_export_archive_snapshot_returns_stable_full_order() {
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
                None,
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
                None,
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
                None,
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
                None,
            )
            .unwrap();

        let mut expected_unpinned = vec![newest, tied, older];
        expected_unpinned.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| right.id.cmp(&left.id))
        });

        let snapshot = core.export_archive_snapshot().unwrap();
        let expected: Vec<String> = std::iter::once(pinned.content)
            .chain(expected_unpinned.into_iter().map(|item| item.content))
            .collect();
        let actual: Vec<String> = snapshot
            .into_iter()
            .map(|entry| entry.item.content)
            .collect();

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
        let pct = core.search("%".into(), None).unwrap();
        assert_eq!(pct.len(), 1, "% 应作为字面量搜索，不匹配所有记录");
        assert_eq!(pct[0].content, "100% done");

        // 搜 "_" 应只匹配 "file_name.txt"，不匹配单字符通配
        let underscore = core.search("_".into(), None).unwrap();
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

        let items = core.get_items(10, 0, None).unwrap();
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

        let items = core.get_items(10, 0, None).unwrap();
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

        let items = core.get_items(10, 0, Some(ClipType::Image)).unwrap();
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

        let items = core.get_items(10, 0, None).unwrap();
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
            None,
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
            None,
        )
        .unwrap();

        let items = core.get_items(10, 0, Some(ClipType::Image)).unwrap();
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
                None,
                vec![],
            )
            .unwrap();

        let items = core.get_items(10, 0, None).unwrap();
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
                None,
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
                None,
                vec![],
            )
            .unwrap();

        let items = core.get_items(10, 0, Some(ClipType::Image)).unwrap();
        assert!(repaired);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].id, existing.id);
        assert_eq!(items[0].paste_count, 1);
        assert!(!items[0].is_pinned);
        assert_eq!(items[0].image_path.as_deref(), Some(restored_path.as_str()));
        assert!(PathBuf::from(restored_path).exists());
    }

    #[test]
    fn test_import_item_if_missing_with_representations_new() {
        let core = setup_core();
        let reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>hi</p>".to_vec(),
        }];
        let imported = core
            .import_item_if_missing(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                1_715_000_000,
                None,
                reps,
            )
            .unwrap();
        assert!(imported);

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 1);
        let loaded_reps = core.get_representations(items[0].id.clone()).unwrap();
        assert_eq!(loaded_reps.len(), 1);
        assert_eq!(loaded_reps[0].uti, "public.html");
        assert_eq!(loaded_reps[0].data, b"<p>hi</p>".to_vec());
    }

    #[test]
    fn test_import_item_if_missing_merges_into_empty_representations() {
        let core = setup_core();
        // 先用空 reps 导入一次（模拟 v1 archive）
        let first = core
            .import_item_if_missing(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                1_715_000_000,
                None,
                vec![],
            )
            .unwrap();
        assert!(first);

        // 再用带 reps 的 archive import；应该补齐并计为 imported
        let reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>hi</p>".to_vec(),
        }];
        let imported = core
            .import_item_if_missing(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                1_715_000_000,
                None,
                reps,
            )
            .unwrap();
        assert!(
            imported,
            "merging representations into empty should count as imported"
        );

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 1);
        let loaded_reps = core.get_representations(items[0].id.clone()).unwrap();
        assert_eq!(loaded_reps.len(), 1);
    }

    #[test]
    fn test_import_item_if_missing_skips_when_representations_exist() {
        let core = setup_core();
        let orig_reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>old</p>".to_vec(),
        }];
        let first = core
            .import_item_if_missing(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                1_715_000_000,
                None,
                orig_reps,
            )
            .unwrap();
        assert!(first);

        // 第二次 import 同 hash 带不同 representations，应该跳过且不覆盖
        let new_reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>new</p>".to_vec(),
        }];
        let imported = core
            .import_item_if_missing(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                false,
                1_715_000_000,
                None,
                new_reps,
            )
            .unwrap();
        assert!(
            !imported,
            "should skip when target already has representations"
        );

        let items = core.get_items(10, 0, None).unwrap();
        let loaded = core.get_representations(items[0].id.clone()).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(
            loaded[0].data,
            b"<p>old</p>".to_vec(),
            "existing representations must NOT be overwritten"
        );
    }

    #[test]
    fn test_export_import_roundtrip_preserves_alias() {
        let core = setup_core();
        let item = core
            .save_item("payload".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("Saved Label".into())).unwrap();

        let snapshot = core.export_archive_snapshot().unwrap();
        assert_eq!(snapshot[0].item.alias.as_deref(), Some("Saved Label"));

        // 导入到一个新库
        let fresh = setup_core();
        let imported = fresh
            .import_item_if_missing(
                "payload".into(), ClipType::Text, None, None, None,
                false, 1_000, Some("Saved Label".into()), vec![],
            )
            .unwrap();
        assert!(imported);
        let items = fresh.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias.as_deref(), Some("Saved Label"));
    }

    #[test]
    fn test_import_if_missing_fills_empty_alias_and_recomputes_pinyin() {
        let core = setup_core();
        // 现有条目无别名
        core.save_item("doc".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 同 hash 导入，备份带中文别名 → 补上、计为 imported、并重算拼音
        let imported = core
            .import_item_if_missing(
                "doc".into(), ClipType::Text, None, None, None,
                false, 2_000, Some("备份名".into()), vec![],
            )
            .unwrap();
        assert!(imported, "现有别名为空、备份有别名应计为 imported");

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].alias.as_deref(), Some("备份名"));

        // 补别名时同步重算了拼音 → 中文别名可被拼音搜到
        // （若漏掉拼音重算，这一行会失败：导入恢复的中文别名搜不到）
        assert_eq!(core.search("beifenming".into(), None).unwrap().len(), 1);
    }

    #[test]
    fn test_import_if_missing_keeps_existing_alias() {
        let core = setup_core();
        let item = core
            .save_item("doc".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("User Edited".into())).unwrap();

        // 同 hash 导入，备份别名不同 → 不覆盖用户已改的别名
        core.import_item_if_missing(
            "doc".into(), ClipType::Text, None, None, None,
            false, 3_000, Some("Backup Name".into()), vec![],
        )
        .unwrap();

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias.as_deref(), Some("User Edited"), "不覆盖用户已有别名");
    }

    #[test]
    fn test_save_item_preserves_alias_on_recopy() {
        let core = setup_core();
        let item = core
            .save_item("foo".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.set_alias(item.id.clone(), Some("会议纪要".into())).unwrap();

        // 同 content 再次复制走去重重写路径（返回新 id），别名必须随快照保留
        core.save_item("foo".into(), ClipType::Text, None, None, None)
            .unwrap();

        let items = core.get_list_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 1, "去重后仍只有一条");
        assert_eq!(
            items[0].alias.as_deref(),
            Some("会议纪要"),
            "重新复制已改名条目不应丢失别名"
        );

        // 重新复制后拼音仍带别名 → 可被拼音搜到
        assert_eq!(core.search("huiyijiyao".into(), None).unwrap().len(), 1);
    }

    #[test]
    fn test_import_item_new_with_chinese_alias_is_pinyin_searchable() {
        let core = setup_core();
        let imported = core
            .import_item_if_missing(
                "payload".into(), ClipType::Text, None, None, None,
                false, 1_000, Some("密钥".into()), vec![],
            )
            .unwrap();
        assert!(imported, "全新条目应计为 imported");

        // 新建导入路径必须把中文别名并入拼音
        assert_eq!(core.search("miyao".into(), None).unwrap().len(), 1);

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias.as_deref(), Some("密钥"));
    }

    #[test]
    fn test_import_item_empty_alias_normalized_to_none() {
        let core = setup_core();
        core.import_item_if_missing(
            "payload".into(), ClipType::Text, None, None, None,
            false, 1_000, Some("".into()), vec![],
        )
        .unwrap();

        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items[0].alias, None, "空字符串别名应归一化为 None");
    }

    #[test]
    fn test_save_item_with_representations() {
        let core = setup_core();
        let reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>hi</p>".to_vec(),
        }];
        let item = core
            .save_item_with_representations(
                "hi".into(),
                ClipType::Text,
                None,
                None,
                None,
                reps,
            )
            .unwrap();

        let loaded = core.get_representations(item.id).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].uti, "public.html");
    }

    #[test]
    fn test_update_content_rewrites_derived_fields() {
        let core = setup_core();
        let item = core
            .save_item("old text".into(), ClipType::Text, None, None, None)
            .unwrap();
        core.increment_paste_count(item.id.clone()).unwrap();

        core.update_content(item.id.clone(), "https://anthropic.com".into(), ClipType::Url)
            .unwrap();

        let updated = core.get_item(item.id.clone()).unwrap();
        assert_eq!(updated.content, "https://anthropic.com");
        assert_eq!(updated.clip_type, ClipType::Url);
        assert_eq!(updated.char_count, 21);
        // 使用信号与身份不变
        assert_eq!(updated.paste_count, 1);
        assert_eq!(updated.created_at, item.created_at);
        assert_eq!(updated.copy_count, item.copy_count);
    }

    #[test]
    fn test_update_content_clears_representations() {
        let core = setup_core();
        let reps = vec![ClipRepresentation {
            uti: "public.html".into(),
            data: b"<p>old</p>".to_vec(),
        }];
        let item = core
            .save_item_with_representations(
                "old".into(), ClipType::Text, None, None, None, reps,
            )
            .unwrap();
        assert_eq!(core.get_representations(item.id.clone()).unwrap().len(), 1);

        core.update_content(item.id.clone(), "new".into(), ClipType::Text)
            .unwrap();
        assert_eq!(
            core.get_representations(item.id.clone()).unwrap().len(),
            0,
            "编辑内容后旧富文本表示应被清空"
        );
    }

    #[test]
    fn test_update_content_allows_duplicate_hash() {
        let core = setup_core();
        core.save_item("twin".into(), ClipType::Text, None, None, None)
            .unwrap();
        let other = core
            .save_item("unique".into(), ClipType::Text, None, None, None)
            .unwrap();

        // 把 other 编辑成与第一条相同的内容：不报错、不合并，库中仍是两条
        core.update_content(other.id.clone(), "twin".into(), ClipType::Text)
            .unwrap();
        let items = core.get_items(10, 0, None).unwrap();
        assert_eq!(items.len(), 2, "用户主动编辑产生的重复内容不去重");
    }

    #[test]
    fn test_update_content_not_found() {
        let core = setup_core();
        let err = core.update_content("no-such-id".into(), "x".into(), ClipType::Text);
        assert!(matches!(err, Err(ClipinError::NotFound { .. })));
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

    #[test]
    fn test_write_attachment_png_uses_image_dir() {
        let (core, img_dir) = setup_core_with_image_dir();

        let path = core
            .write_attachment_png("item-123".into(), 2, b"cached-png".to_vec())
            .unwrap();

        assert_eq!(PathBuf::from(&path).parent(), Some(img_dir.as_path()));
        assert!(
            path.ends_with("item-123_2.png"),
            "attachment filename must be stable for item/index cleanup"
        );
        assert_eq!(fs::read(path).unwrap(), b"cached-png");
    }

    #[test]
    fn test_file_item_carries_attachment_paths_and_delete_removes_cached_files() {
        let (core, img_dir) = setup_core_with_image_dir();
        let first = write_image(&img_dir, "cached-a.png", b"a");
        let second = write_image(&img_dir, "cached-b.png", b"b");
        let attachment_paths = format!("[\"{}\",\"{}\"]", first, second);

        let item = core
            .save_item_with_attachment_paths(
                "file-item-1".into(),
                "/tmp/original-a.jpg\n/tmp/original-b.jpg".into(),
                ClipType::File,
                None,
                None,
                None,
                Some(attachment_paths.clone()),
                vec![],
            )
            .unwrap();
        assert_eq!(item.attachment_paths.as_deref(), Some(attachment_paths.as_str()));

        let fetched = core.get_item(item.id.clone()).unwrap();
        assert_eq!(fetched.attachment_paths.as_deref(), Some(attachment_paths.as_str()));

        let list = core.get_list_items(10, 0, Some(ClipType::File)).unwrap();
        assert_eq!(list[0].attachment_paths.as_deref(), Some(attachment_paths.as_str()));

        core.delete_item(item.id).unwrap();
        assert!(!PathBuf::from(first).exists());
        assert!(!PathBuf::from(second).exists());
    }
}
