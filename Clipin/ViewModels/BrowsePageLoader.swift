import Foundation

/// 浏览/搜索的分页取数 + 可见性过滤收口。从 ClipboardViewModel 抽出:
/// 按 query/browseMode 选 core API、算 typeFilter、按 pinned 展示策略过滤。
/// fetchPage throws(UI notice 副作用收回 VM catch),不内部吞成空。
/// @MainActor:读 SettingsStore.pinnedItemsPresentation(main actor 隔离),调用方(VM/测试)均在主线程。
@MainActor
struct BrowsePageLoader {
    let core: ClipinCore
    let settings: SettingsStore

    struct Page {
        let items: [ClipListItem]
        let rawCount: Int
        let hasMore: Bool
    }

    func effectiveTypeFilter(query: String, browseMode: LauncherBrowseMode) -> ClipType? {
        if query.isEmpty {
            return browseMode.typeFilter
        }
        return browseMode.isPinnedOnly ? nil : browseMode.typeFilter
    }

    func shouldShowPinnedSection(query: String, browseMode: LauncherBrowseMode) -> Bool {
        guard query.isEmpty, !browseMode.isPinnedOnly else { return false }
        return settings.pinnedItemsPresentation == .topSection
    }

    /// 搜索全局召回不过滤;浏览态按 pinned 展示策略过滤;末了剔除 excludingID(pending 删除)。
    func visible(_ items: [ClipListItem],
                 query: String,
                 browseMode: LauncherBrowseMode,
                 excludingID: String?) -> [ClipListItem] {
        let filtered: [ClipListItem]
        if !query.isEmpty {
            filtered = items
        } else if browseMode.isPinnedOnly {
            filtered = items.filter(\.isPinned)
        } else if settings.pinnedItemsPresentation == .pinnedOnlyView {
            filtered = items.filter { !$0.isPinned }
        } else {
            filtered = items
        }
        guard let excludingID else { return filtered }
        return filtered.filter { $0.id != excludingID }
    }

    /// 按 mode 选 core API 取一页,内部已做 visible 过滤。失败抛出由 VM catch。
    func fetchPage(offset: Int,
                   pageSize: Int,
                   query: String,
                   browseMode: LauncherBrowseMode,
                   excludingID: String?) throws -> Page {
        let typeFilter = effectiveTypeFilter(query: query, browseMode: browseMode)
        let chunk: [ClipListItem]
        if browseMode.isPinnedOnly {
            chunk = try core.getPinnedListItems(
                limit: Int32(pageSize), offset: Int32(offset), typeFilter: typeFilter)
        } else if settings.pinnedItemsPresentation == .pinnedOnlyView {
            chunk = try core.getUnpinnedListItems(
                limit: Int32(pageSize), offset: Int32(offset), typeFilter: typeFilter)
        } else {
            chunk = try core.getListItems(
                limit: Int32(pageSize), offset: Int32(offset), typeFilter: typeFilter)
        }
        return Page(
            items: visible(chunk, query: query, browseMode: browseMode, excludingID: excludingID),
            rawCount: chunk.count,
            hasMore: chunk.count == pageSize
        )
    }
}
