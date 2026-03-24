import Foundation
import SwiftUI

/// 剪贴板历史 ViewModel
@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var selectedItem: ClipItem?
    @Published var searchQuery: String = ""
    @Published var typeFilter: ClipType?

    private let core: ClipinCore

    init(core: ClipinCore) {
        self.core = core
    }

    func loadItems() {
        if searchQuery.isEmpty {
            items = core.getItems(limit: 100, offset: 0, typeFilter: typeFilter)
        } else {
            items = core.search(query: searchQuery, typeFilter: typeFilter)
        }
        // 自动选中第一个
        if selectedItem == nil || !items.contains(where: { $0.id == selectedItem?.id }) {
            selectedItem = items.first
        }
    }

    func togglePin(_ item: ClipItem) {
        _ = try? core.togglePin(id: item.id)
        loadItems()
    }

    func deleteItem(_ item: ClipItem) {
        try? core.deleteItem(id: item.id)
        if selectedItem?.id == item.id {
            selectedItem = nil
        }
        loadItems()
    }

    /// 按日期分组
    var groupedItems: [(String, [ClipItem])] {
        let calendar = Calendar.current
        let now = Date()

        var pinned: [ClipItem] = []
        var today: [ClipItem] = []
        var yesterday: [ClipItem] = []
        var older: [String: [ClipItem]] = [:]

        for item in items {
            if item.isPinned {
                pinned.append(item)
                continue
            }

            let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)

            if calendar.isDateInToday(date) {
                today.append(item)
            } else if calendar.isDateInYesterday(date) {
                yesterday.append(item)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "M月d日"
                let key = formatter.string(from: date)
                older[key, default: []].append(item)
            }
        }

        var result: [(String, [ClipItem])] = []
        if !pinned.isEmpty { result.append(("📌 Pinned", pinned)) }
        if !today.isEmpty { result.append(("Today", today)) }
        if !yesterday.isEmpty { result.append(("Yesterday", yesterday)) }

        let sortedOlder = older.sorted { a, b in
            (a.value.first?.createdAt ?? 0) > (b.value.first?.createdAt ?? 0)
        }
        for (key, items) in sortedOlder {
            result.append((key, items))
        }

        return result
    }
}
