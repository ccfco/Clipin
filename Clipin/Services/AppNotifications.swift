import Foundation

extension Notification.Name {
    static let clipHistoryDidChange = Notification.Name("ClipHistoryDidChange")
    static let clipHistoryItemSaved = Notification.Name("ClipHistoryItemSaved")
    static let clipinRestoreSearchFocus = Notification.Name("ClipinRestoreSearchFocus")
    static let clipinPreviewVisibilityDidChange = Notification.Name("ClipinPreviewVisibilityDidChange")
    static let clipinPreviewSelectionDidChange = Notification.Name("ClipinPreviewSelectionDidChange")
    static let clipboardItemOcrUpdated = Notification.Name("ClipboardItemOcrUpdated")
    /// 语义标签写回完成（选中项内容字段更新，但列表顺序不变）。
    static let clipboardItemAiTagsUpdated = Notification.Name("ClipboardItemAiTagsUpdated")
    /// App Intent：打开 launcher。
    static let clipinIntentOpenRequested = Notification.Name("ClipinIntentOpenRequested")
    /// App Intent：打开 launcher 并带上搜索词（object 为 String）。
    static let clipinIntentSearchRequested = Notification.Name("ClipinIntentSearchRequested")
}
