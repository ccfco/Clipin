import Foundation

/// items → 分组 sections 的纯函数收口。从 ClipboardViewModel 抽出:不持有状态、
/// 不参与渲染拓扑,只按「Pinned / Today / Yesterday / 本地化月日」分组。
/// flatOrder / shortcutOrder 等渲染派生态留在 VM。
enum ClipSectionBuilder {
    /// showPinnedSection=true:先析出 isPinned 项成 Pinned 组,其余按日期分组。
    static func build(items: [ClipListItem], showPinnedSection: Bool) -> [ClipSection] {
        guard showPinnedSection else {
            return makeDateSections(from: items)
        }
        let pinnedItems = items.filter(\.isPinned)
        let regularItems = items.filter { !$0.isPinned }
        var result: [ClipSection] = []
        if !pinnedItems.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Pinned", comment: ""), items: pinnedItems))
        }
        result.append(contentsOf: makeDateSections(from: regularItems))
        return result
    }

    /// section 标题用的简短月日格式。locale 自适应让 macOS 按当前 locale 选 month/day 排序
    /// (en: "May 20", zh: "5月20日"),避免硬编码 "M月d日" 在英文环境也显中文。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("Md")
        return f
    }()

    private static func makeDateSections(from items: [ClipListItem]) -> [ClipSection] {
        let calendar = Calendar.current
        var today: [ClipListItem] = []
        var yesterday: [ClipListItem] = []
        var older: [(key: String, items: [ClipListItem])] = []
        var olderMap: [String: Int] = [:]

        for item in items {
            let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)
            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else {
                let key = dateFormatter.string(from: date)
                if let idx = olderMap[key] {
                    older[idx].items.append(item)
                } else {
                    olderMap[key] = older.count
                    older.append((key: key, items: [item]))
                }
            }
        }

        var result: [ClipSection] = []
        if !today.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Today", comment: ""), items: today))
        }
        if !yesterday.isEmpty {
            result.append(ClipSection(title: NSLocalizedString("Yesterday", comment: ""), items: yesterday))
        }
        for group in older {
            result.append(ClipSection(title: group.key, items: group.items))
        }
        return result
    }
}
