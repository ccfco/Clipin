import AppKit
import Foundation
import SwiftUI
import Combine

struct ClipSection: Identifiable {
    let title: String
    let items: [ClipListItem]
    var id: String { title }
}

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var selectedItem: ClipItem?
    @Published var selectedItemID: String?
    @Published var searchQuery: String = ""
    @Published var typeFilter: ClipType?
    @Published private(set) var sections: [ClipSection] = []
    @Published var targetAppName: String?

    private let core: ClipinCore
    private var items: [ClipListItem] = []
    private var flatOrder: [ClipListItem] = []
    private var debounce: AnyCancellable?
    private var loadItemTask: Task<Void, Never>?

    var onPasteRequested: ((ClipItem) -> Void)?
    var onPastePlainRequested: ((ClipItem) -> Void)?
    var onCopyRequested: ((ClipItem) -> Void)?
    var onCloseRequested: (() -> Void)?

    init(core: ClipinCore) {
        self.core = core
        debounce = Publishers.CombineLatest($searchQuery, $typeFilter)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.loadItems() }
    }

    // MARK: - Load

    func loadItems(selectLatest: Bool = false) {
        let currentSelectionID = selectLatest ? nil : selectedItemID

        if searchQuery.isEmpty {
            items = core.getListItems(limit: 200, offset: 0, typeFilter: typeFilter)
        } else {
            items = core.searchListItems(query: searchQuery, typeFilter: typeFilter)
        }
        rebuildSections()

        let nextID: String?
        if let currentSelectionID,
           items.contains(where: { $0.id == currentSelectionID }) {
            nextID = currentSelectionID
        } else {
            nextID = flatOrder.first?.id
        }
        selectItem(id: nextID)
    }

    // MARK: - Selection

    func selectItem(id: String?) {
        loadItemTask?.cancel()
        selectedItemID = id
        guard let id else {
            selectedItem = nil
            return
        }
        // 主线程立即更新 ID（选中高亮即时响应），后台加载完整 item（避免 SQLite 阻塞主线程）
        let core = self.core
        let capturedId = id
        loadItemTask = Task {
            let item = try? await Task.detached(priority: .userInteractive) {
                try core.getItem(id: capturedId)
            }.value
            guard !Task.isCancelled, self.selectedItemID == capturedId else { return }
            self.selectedItem = item
        }
    }

    func selectNext() {
        guard !flatOrder.isEmpty else { return }
        guard let currentID = selectedItemID,
              let idx = flatOrder.firstIndex(where: { $0.id == currentID }) else {
            selectItem(id: flatOrder.first?.id)
            return
        }
        selectItem(id: flatOrder[min(idx + 1, flatOrder.count - 1)].id)
    }

    func selectPrev() {
        guard !flatOrder.isEmpty else { return }
        guard let currentID = selectedItemID,
              let idx = flatOrder.firstIndex(where: { $0.id == currentID }) else {
            selectItem(id: flatOrder.last?.id)
            return
        }
        selectItem(id: flatOrder[max(idx - 1, 0)].id)
    }

    /// 按视觉顺序的第 index 项（0-based）直接粘贴
    func pasteItemAt(index: Int) {
        guard index >= 0, index < flatOrder.count else { return }
        let id = flatOrder[index].id
        guard let item = try? core.getItem(id: id) else { return }
        onPasteRequested?(item)
    }

    // MARK: - Actions

    func pasteSelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        onPasteRequested?(item)
    }

    func pastePlainSelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        onPastePlainRequested?(item)
    }

    func copySelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        onCopyRequested?(item)
    }

    func openSelected() {
        guard let item = selectedItem else { return }
        switch item.clipType {
        case .url:
            if let url = URL(string: item.content) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            let url = URL(fileURLWithPath: item.content)
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }

    func close() { onCloseRequested?() }

    func togglePinSelected() {
        guard let selectedItemID else { return }
        _ = try? core.togglePin(id: selectedItemID)
        loadItems()
    }

    func togglePin(id: String) {
        _ = try? core.togglePin(id: id)
        loadItems()
    }

    func deleteSelected() {
        guard let id = selectedItemID else { return }
        deleteItem(id: id)
    }

    func deleteItem(id: String) {
        // 删除前记住相邻项，删除后自动选中
        var nextSelectionID: String?
        if selectedItemID == id, let idx = flatOrder.firstIndex(where: { $0.id == id }) {
            if idx + 1 < flatOrder.count {
                nextSelectionID = flatOrder[idx + 1].id
            } else if idx > 0 {
                nextSelectionID = flatOrder[idx - 1].id
            }
        }

        try? core.deleteItem(id: id)

        if selectedItemID == id {
            selectedItemID = nextSelectionID
            selectedItem = nil
        }
        loadItems()
    }

    var selectedListItem: ClipListItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    /// 列表是否为空（用于空状态提示）
    var isEmpty: Bool { flatOrder.isEmpty }

    /// 是否正在搜索或过滤
    var hasActiveFilter: Bool { !searchQuery.isEmpty || typeFilter != nil }

    // MARK: - Private

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    private func rebuildSections() {
        let calendar = Calendar.current
        var pinned: [ClipListItem] = []
        var today: [ClipListItem] = []
        var yesterday: [ClipListItem] = []
        var older: [(key: String, items: [ClipListItem])] = []
        var olderMap: [String: Int] = [:]

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
                let key = Self.dateFormatter.string(from: date)
                if let idx = olderMap[key] {
                    older[idx].items.append(item)
                } else {
                    olderMap[key] = older.count
                    older.append((key: key, items: [item]))
                }
            }
        }

        var result: [ClipSection] = []
        if !pinned.isEmpty    { result.append(ClipSection(title: "Pinned", items: pinned)) }
        if !today.isEmpty     { result.append(ClipSection(title: "Today", items: today)) }
        if !yesterday.isEmpty { result.append(ClipSection(title: "Yesterday", items: yesterday)) }
        for group in older {
            result.append(ClipSection(title: group.key, items: group.items))
        }

        sections = result
        flatOrder = result.flatMap(\.items)
    }
}
