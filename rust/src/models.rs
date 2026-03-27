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
    pub char_count: i32,
    pub copy_count: i32,
    pub first_copied_at: i64,
    /// Vision OCR 识别结果，仅 image 类型有值，异步写入
    pub ocr_text: Option<String>,
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
    pub char_count: i32,
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
