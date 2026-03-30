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
    @Published var isShowingActions = false
    @Published var selectedActionIndex = 0
    @Published private(set) var paletteActions: [PaletteAction] = []
    @Published var isContinuousPasteEnabled: Bool = false

    func navigatePalette(delta: Int) {
        let count = paletteActions.count
        guard count > 0 else { return }
        selectedActionIndex = max(0, min(count - 1, selectedActionIndex + delta))
    }

    func executeSelectedPaletteAction() {
        executePaletteAction(at: selectedActionIndex)
    }

    func executePaletteAction(at index: Int) {
        guard index >= 0, index < paletteActions.count else { return }
        let shouldRestoreSearchFocus = isShowingActions
        let action = paletteActions[index]
        action.handler()

        if isShowingActions {
            hideActionsPalette(restoreFocus: true)
        } else if shouldRestoreSearchFocus {
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    func toggleActionsPalette() {
        isShowingActions ? hideActionsPalette(restoreFocus: true) : showActionsPalette()
    }

    func showActionsPalette() {
        let actions = ActionPaletteBuilder.actions(for: self)
        guard !actions.isEmpty else { return }
        paletteActions = actions
        selectedActionIndex = min(selectedActionIndex, max(actions.count - 1, 0))
        isShowingActions = true
    }

    func hideActionsPalette(restoreFocus: Bool = false) {
        isShowingActions = false
        paletteActions = []
        selectedActionIndex = 0

        if restoreFocus {
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    private let core: ClipinCore
    private var items: [ClipListItem] = []
    private var flatOrder: [ClipListItem] = []
    /// ⌘1-9 快捷粘贴序列：只含非 pinned 项，pinned 项不占用快捷键位置
    private var shortcutOrder: [ClipListItem] = []
    private var debounce: AnyCancellable?
    private var ocrSubscription: AnyCancellable?
    private var loadItemTask: Task<Void, Never>?
    private var skipNextDebouncedLoad = false

    var onPasteRequested: ((ClipItem) -> Void)?
    var onPastePlainRequested: ((ClipItem) -> Void)?
    var onCopyRequested: ((ClipItem) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onOpenSettingsRequested: (() -> Void)?

    init(core: ClipinCore) {
        self.core = core
        debounce = Publishers.CombineLatest($searchQuery, $typeFilter)
            .dropFirst()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                guard let self else { return }
                if self.skipNextDebouncedLoad {
                    self.skipNextDebouncedLoad = false
                    return
                }
                self.loadItems()
            }
        // OCR 完成后刷新列表，让图片条目显示识别文字
        ocrSubscription = NotificationCenter.default
            .publisher(for: .clipboardItemOcrUpdated)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.loadItems() }
    }

    // MARK: - Load

    func loadItems(selectLatest: Bool = false) {
        if isShowingActions {
            hideActionsPalette()
        }

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
            let item = try? await Task.detached(priority: .userInitiated) {
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

    /// 按 ⌘1-9 快捷键序列的第 index 项（0-based）直接粘贴，pinned 项不在此序列中
    func pasteItemAt(index: Int) {
        guard index >= 0, index < shortcutOrder.count else { return }
        let id = shortcutOrder[index].id
        guard let item = try? core.getItem(id: id) else { return }
        onPasteRequested?(item)
    }

    // MARK: - Actions

    func pasteSelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        try? core.touchItem(id: selectedItemID)
        onPasteRequested?(item)
    }

    func pastePlainSelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        try? core.touchItem(id: selectedItemID)
        onPastePlainRequested?(item)
    }

    func copySelected() {
        guard let selectedItemID else { return }
        guard let item = try? core.getItem(id: selectedItemID) else { return }
        onCopyRequested?(item)
    }

    func openSelected() {
        guard let item = currentSelectedItem() else { return }
        switch item.clipType {
        case .url:
            if let url = URL(string: item.content) {
                NSWorkspace.shared.open(url)
            }
        case .file:
            let urls = FileClipboardContent.paths(from: item.content)
                .map(URL.init(fileURLWithPath:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        default:
            break
        }
    }

    func close() { onCloseRequested?() }

    func openSettings() { onOpenSettingsRequested?() }

    func toggleContinuousPaste() { isContinuousPasteEnabled.toggle() }

    func setTypeFilterByIndex(_ index: Int) {
        switch index {
        case 0: typeFilter = nil
        case 1: typeFilter = .text
        case 2: typeFilter = .image
        case 3: typeFilter = .file
        case 4: typeFilter = .url
        default: break
        }
    }

    func cycleTypeFilter(reverse: Bool = false) {
        let filters: [ClipType?] = [nil, .text, .image, .file, .url]
        guard let currentIndex = filters.firstIndex(where: { $0 == typeFilter }) else {
            typeFilter = nil
            return
        }

        let nextIndex: Int
        if reverse {
            nextIndex = currentIndex == 0 ? filters.count - 1 : currentIndex - 1
        } else {
            nextIndex = (currentIndex + 1) % filters.count
        }
        typeFilter = filters[nextIndex]
    }

    @discardableResult
    func clearActiveQueryAndFilters() -> Bool {
        guard hasActiveFilter else { return false }
        skipNextDebouncedLoad = true
        searchQuery = ""
        typeFilter = nil
        loadItems()
        return true
    }

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
        if isShowingActions {
            hideActionsPalette()
        }

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

    var selectedQuickPasteNumber: Int? {
        guard let selectedItemID else { return nil }
        guard let index = shortcutOrder.firstIndex(where: { $0.id == selectedItemID }), index < 9 else { return nil }
        return index + 1
    }

    var selectedQuickPasteLabel: String {
        selectedQuickPasteNumber == nil
            ? NSLocalizedString("Top 9", comment: "")
            : NSLocalizedString("Quick Paste", comment: "")
    }

    var selectedQuickPasteKey: String {
        if let number = selectedQuickPasteNumber {
            return "⌘\(number)"
        }
        return "⌘1-9"
    }

    /// 列表是否为空（用于空状态提示）
    var isEmpty: Bool { flatOrder.isEmpty }

    /// 是否正在搜索或过滤
    var hasActiveFilter: Bool { !searchQuery.isEmpty || typeFilter != nil }

    var canOpenSelectedItem: Bool {
        guard let item = selectedListItem else { return false }
        return item.clipType == .url || item.clipType == .file
    }

    var selectedOpenLabel: String {
        guard let item = selectedListItem else { return NSLocalizedString("Open", comment: "") }
        switch item.clipType {
        case .url:
            return NSLocalizedString("Open URL", comment: "")
        case .file:
            return NSLocalizedString("Reveal in Finder", comment: "")
        default:
            return NSLocalizedString("Open", comment: "")
        }
    }

    var selectedOpenSystemImage: String {
        guard let item = selectedListItem else { return "arrow.up.right.square" }
        switch item.clipType {
        case .url:
            return "safari"
        case .file:
            return "folder"
        default:
            return "arrow.up.right.square"
        }
    }

    // MARK: - Private

    func currentSelectedItem() -> ClipItem? {
        guard let selectedItemID else { return nil }
        if selectedItem?.id == selectedItemID {
            return selectedItem
        }
        return try? core.getItem(id: selectedItemID)
    }

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
        if !pinned.isEmpty    { result.append(ClipSection(title: NSLocalizedString("Pinned", comment: ""), items: pinned)) }
        if !today.isEmpty     { result.append(ClipSection(title: NSLocalizedString("Today", comment: ""), items: today)) }
        if !yesterday.isEmpty { result.append(ClipSection(title: NSLocalizedString("Yesterday", comment: ""), items: yesterday)) }
        for group in older {
            result.append(ClipSection(title: group.key, items: group.items))
        }

        sections = result
        flatOrder = result.flatMap(\.items)
        shortcutOrder = flatOrder.filter { !$0.isPinned }
    }
}
