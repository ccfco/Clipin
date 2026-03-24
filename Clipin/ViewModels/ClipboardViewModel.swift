import Foundation
import SwiftUI

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var selectedItem: ClipItem?
    @Published var searchQuery: String = ""
    @Published var typeFilter: ClipType?

    private let core: ClipinCore

    // AppDelegate 负责处理粘贴和关闭，ViewModel 只上报事件
    var onPasteRequested: ((ClipItem) -> Void)?
    var onCloseRequested: (() -> Void)?

    init(core: ClipinCore) {
        self.core = core
    }

    func loadItems() {
        if searchQuery.isEmpty {
            items = core.getItems(limit: 200, offset: 0, typeFilter: typeFilter)
        } else {
            items = core.search(query: searchQuery, typeFilter: typeFilter)
        }
        // 保持当前选中，若已不在列表中则选第一个
        if selectedItem == nil || !items.contains(where: { $0.id == selectedItem?.id }) {
            selectedItem = items.first
        }
    }

    func pasteSelected() {
        guard let item = selectedItem else { return }
        onPasteRequested?(item)
    }

    func close() {
        onCloseRequested?()
    }

    func togglePin(_ item: ClipItem) {
        _ = try? core.togglePin(id: item.id)
        loadItems()
    }

    func deleteItem(_ item: ClipItem) {
        try? core.deleteItem(id: item.id)
        if selectedItem?.id == item.id { selectedItem = nil }
        loadItems()
    }

    // MARK: - 按日期分组

    var groupedItems: [(String, [ClipItem])] {
        let calendar = Calendar.current
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
                older[formatter.string(from: date), default: []].append(item)
            }
        }

        var result: [(String, [ClipItem])] = []
        if !pinned.isEmpty    { result.append(("📌 Pinned", pinned)) }
        if !today.isEmpty     { result.append(("Today", today)) }
        if !yesterday.isEmpty { result.append(("Yesterday", yesterday)) }
        for (key, items) in older.sorted(by: { ($0.value.first?.createdAt ?? 0) > ($1.value.first?.createdAt ?? 0) }) {
            result.append((key, items))
        }
        return result
    }
}
