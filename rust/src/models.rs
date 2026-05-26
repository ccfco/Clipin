/// 剪贴板内容类型
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ClipType {
    Text,
    Image,
    File,
    Url,
}

impl ClipType {
    pub fn as_str(&self) -> &'static str {
        match self {
            ClipType::Text => "text",
            ClipType::Image => "image",
            ClipType::File => "file",
            ClipType::Url => "url",
        }
    }

    pub fn from_str(s: &str) -> Self {
        match s {
            "image" => ClipType::Image,
            "file" => ClipType::File,
            "url" => ClipType::Url,
            _ => ClipType::Text,
        }
    }
}

/// 单条剪贴板记录
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClipItem {
    pub id: String,
    pub content: String,
    pub clip_type: ClipType,
    pub source_app: Option<String>,
    pub source_name: Option<String>,
    pub is_pinned: bool,
    pub created_at: i64,
    pub image_path: Option<String>,
    /// file 类型的图片附件缓存路径 JSON 数组。图片 bytes 仍在磁盘，不进入 SQLite BLOB。
    pub attachment_paths: Option<String>,
    pub char_count: i32,
    pub copy_count: i32,
    pub first_copied_at: i64,
    /// Vision OCR 识别结果，仅 image 类型有值，异步写入
    pub ocr_text: Option<String>,
    /// 用户通过 Clipin 粘贴的次数（首要排序信号）
    pub paste_count: i32,
    /// 用户自定义别名（显示名）。None 表示未命名，列表回退到内容兜底预览。
    pub alias: Option<String>,
}

/// 列表使用的轻量摘要记录，避免长文本拖慢整个面板
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClipListItem {
    pub id: String,
    pub preview: String,
    pub clip_type: ClipType,
    pub source_app: Option<String>,
    pub source_name: Option<String>,
    pub is_pinned: bool,
    pub created_at: i64,
    pub image_path: Option<String>,
    /// file 类型的图片附件缓存路径 JSON 数组，列表预览/Quick Look 用。
    pub attachment_paths: Option<String>,
    pub char_count: i32,
    pub paste_count: i32,
    pub copy_count: i32,
    /// 图片像素尺寸，仅 image 类型有值；采集时与历史 backfill 异步写入
    pub image_width: Option<i32>,
    pub image_height: Option<i32>,
    /// 用户自定义别名。None 表示未命名；非 None 时列表行画"有别名"视觉信号，
    /// 且 Swift displayTitle 按"别名优先"推导显示名。
    pub alias: Option<String>,
}

/// 错误类型
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ClipinError {
    #[error("Storage error: {message}")]
    StorageError { message: String },
    #[error("Item not found: {id}")]
    NotFound { id: String },
}

impl From<rusqlite::Error> for ClipinError {
    fn from(e: rusqlite::Error) -> Self {
        ClipinError::StorageError {
            message: e.to_string(),
        }
    }
}

impl From<std::io::Error> for ClipinError {
    fn from(e: std::io::Error) -> Self {
        ClipinError::StorageError {
            message: e.to_string(),
        }
    }
}

/// 单条剪贴板条目的一种 UTI representation
/// 仅适用于 text 和 url 类型；image / file 不存额外 representation
#[derive(Debug, Clone, uniffi::Record)]
pub struct ClipRepresentation {
    pub uti: String,
    pub data: Vec<u8>,
}

/// 导出专用快照：一条 item 及其全部 representations。
/// 二者必须在同一把 DB 锁内一次性读出，原因见 `Storage::export_archive_snapshot`。
#[derive(Debug, Clone, uniffi::Record)]
pub struct ArchiveSnapshotItem {
    pub item: ClipItem,
    pub representations: Vec<ClipRepresentation>,
}
