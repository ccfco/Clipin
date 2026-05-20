import AppKit
import Foundation
import SwiftUI
import Combine

struct ClipSection: Identifiable {
    let title: String
    let items: [ClipListItem]
    var id: String { title }
}

enum LauncherNoticeStyle {
    case info
    case success
    case warning
    case error
}

struct LauncherNotice: Identifiable {
    let id = UUID()
    let text: String
    let style: LauncherNoticeStyle
    let actionTitle: String?
}

@MainActor
final class ClipboardViewModel: ObservableObject {
    /// `selectedItem` 是"异步加载的完整 payload"，与同步设值的 `selectedItemID` 形成双轨流。
    /// 强制 private(set) 让外部只能通过 `selectItem(id:)` 改变选中状态，杜绝绕过 ID-match guard
    /// 的可能；消费者一律走 `displayedItem` 读取，由编译器替注释把关。
    @Published private(set) var selectedItem: ClipItem?
    @Published var selectedItemID: String?

    /// PreviewPane 等"右侧 payload 消费者"的唯一入口：仅在 ID 匹配时返回 selectedItem。
    /// `selectItem(id:)` 同步切换 selectedItemID、异步加载完整 ClipItem，这中间存在时间窗口；
    /// 直读 selectedItem 会在窗口内显示上一次选中项的数据（"左选 A、右显 B"）。
    /// 该 guard 与异步回调里的 `self.selectedItemID == capturedId` 同源，把规则收口到消费侧。
    var displayedItem: ClipItem? {
        guard let selectedItemID, selectedItem?.id == selectedItemID else { return nil }
        return selectedItem
    }
    @Published var searchQuery: String = ""
    @Published var browseMode: LauncherBrowseMode = .all
    @Published private(set) var sections: [ClipSection] = []
    @Published var targetAppName: String?
    @Published var isShowingActions = false
    @Published var selectedActionIndex = 0
    @Published private(set) var paletteActions: [PaletteAction] = []
    @Published var isContinuousPasteEnabled: Bool = false
    @Published private(set) var launcherNotice: LauncherNotice?
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var selectedRepresentationUTIs: [String] = []

    func navigatePalette(delta: Int) {
        let count = paletteActions.count
        guard count > 0 else { return }
        selectedActionIndex = (selectedActionIndex + delta + count) % count
    }

    func executeSelectedPaletteAction() {
        executePaletteAction(at: selectedActionIndex)
    }

    func executePaletteAction(at index: Int) {
        guard index >= 0, index < paletteActions.count else { return }
        let action = paletteActions[index]
        let shouldRestoreSearchFocus = isShowingActions && action.restoresSearchFocus
        action.handler()

        if isShowingActions {
            hideActionsPalette(restoreFocus: action.restoresSearchFocus)
        } else if shouldRestoreSearchFocus {
            NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
        }
    }

    @discardableResult
    func executePaletteShortcut(_ shortcut: PaletteActionShortcut) -> Bool {
        guard isShowingActions,
              let index = paletteActions.firstIndex(where: { $0.shortcut == shortcut }) else {
            return false
        }
        executePaletteAction(at: index)
        return true
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
    private let settings: SettingsStore
    private var items: [ClipListItem] = []
    private var flatOrder: [ClipListItem] = []
    /// ⌘1-9 快捷粘贴序列：始终基于当前可见列表
    private(set) var shortcutOrder: [ClipListItem] = []
    private var debounce: AnyCancellable?
    private var ocrSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var loadItemTask: Task<Void, Never>?
    private var skipNextDebouncedLoad = false
    private var sessionBaseBrowseMode: LauncherBrowseMode
    private var noticeTask: Task<Void, Never>?
    private var noticeAction: (() -> Void)?
    private var previewTask: Task<Void, Never>?

    private struct PendingDeletion {
        let id: String
    }

    private var pendingDeletion: PendingDeletion?
    private var pendingDeletionTask: Task<Void, Never>?

    // MARK: - Pagination
    private static let pageSize = 50
    private static let previewNeighborItemLimit = 80
    /// 当前已从 DB 加载的条目总数（用于 offset 计算）
    private var totalLoadedFromDB = 0
    /// 是否还有更多可加载的条目（非 pinned 浏览模式、非搜索时有效）
    @Published private(set) var hasMore = false

    var onPasteRequested: ((ClipItem) -> Void)?
    var onPastePlainRequested: ((ClipItem) -> Void)?
    var onPasteRepresentationRequested: ((ClipItem, String) -> Void)?
    var onCopyRequested: ((ClipItem) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onOpenSettingsRequested: (() -> Void)?

    init(core: ClipinCore, settings: SettingsStore = .shared) {
        self.core = core
        self.settings = settings
        self.sessionBaseBrowseMode = settings.resolvedLaunchBrowseMode()
        self.browseMode = settings.resolvedLaunchBrowseMode()
        debounce = Publishers.CombineLatest($searchQuery, $browseMode)
            .dropFirst()
            .handleEvents(receiveOutput: { [weak self] _, mode in
                self?.settings.recordLastLauncherBrowseMode(mode)
            })
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
            .sink { [weak self] _ in self?.loadItems(hidesActions: false) }
        settingsSubscription = settings.$pinnedItemsPresentation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.loadItems() }
    }

    // MARK: - Load

    /// 重新加载列表。后台 OCR 这类静默刷新会保留当前动作面板，避免用户正在选命令时被打断。
    func loadItems(selectLatest: Bool = false, hidesActions: Bool = true) {
        if hidesActions, isShowingActions {
            hideActionsPalette()
        }

        let currentSelectionID = selectLatest ? nil : selectedItemID
        totalLoadedFromDB = 0

        let typeFilter = effectiveTypeFilter
        if searchQuery.isEmpty {
            let page = fetchBrowsePage(offset: 0, typeFilter: typeFilter)
            items = page.items
            totalLoadedFromDB = page.rawCount
            hasMore = page.hasMore
        } else {
            items = core.searchListItems(query: searchQuery, typeFilter: typeFilter)
            hasMore = false
        }
        items = visibleItems(from: items)
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

    /// 滚到底时加载下一页，追加到 items 并重建 sections（不重置选中状态）
    func loadMoreItems() {
        guard hasMore, searchQuery.isEmpty else { return }
        let page = fetchBrowsePage(offset: totalLoadedFromDB, typeFilter: effectiveTypeFilter)
        guard !page.items.isEmpty || page.hasMore else {
            hasMore = false
            return
        }
        items.append(contentsOf: page.items)
        totalLoadedFromDB += page.rawCount
        hasMore = page.hasMore
        rebuildSections()
    }

    // MARK: - Selection

    func selectItem(id: String?) {
        loadItemTask?.cancel()
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        selectedItemID = id
        reloadRepresentationsForSelected()
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

    func reloadRepresentationsForSelected() {
        guard let id = selectedItemID else {
            selectedRepresentationUTIs = []
            return
        }
        let core = self.core
        Task.detached(priority: .userInitiated) { [weak self] in
            let reps = (try? core.getRepresentations(id: id)) ?? []
            await MainActor.run {
                guard let self else { return }
                guard self.selectedItemID == id else { return }
                self.selectedRepresentationUTIs = reps.map { $0.uti }
            }
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

    /// 按 ⌘1-9 快捷键序列的第 index 项（0-based）直接粘贴
    func pasteItemAt(index: Int) {
        guard index >= 0, index < shortcutOrder.count else { return }
        guard let item = loadItem(id: shortcutOrder[index].id, touch: true) else { return }
        onPasteRequested?(item)
    }

    // MARK: - Actions

    func pasteSelected() {
        guard let id = selectedItemID, let item = loadItem(id: id, touch: true) else { return }
        onPasteRequested?(item)
    }

    func pastePlainSelected() {
        guard let id = selectedItemID, let item = loadItem(id: id, touch: true) else { return }
        onPastePlainRequested?(item)
    }

    func pasteRepresentationSelected(uti: String) {
        guard let id = selectedItemID, let item = loadItem(id: id, touch: true) else { return }
        onPasteRepresentationRequested?(item, uti)
    }

    /// 当前选中条目可用的 "Paste as X" 动作（仅 HTML / RTF）。
    /// 仅在 text/url 且确实存在对应 UTI 时才返回对应条目；否则返回空数组。
    /// "Paste as Plain Text" 由 ActionPaletteBuilder 单独处理，不在此返回。
    func representationActions(for item: ClipItem) -> [PaletteAction] {
        guard item.clipType == .text || item.clipType == .url else { return [] }
        let utis = Set(selectedRepresentationUTIs)
        var actions: [PaletteAction] = []
        if utis.contains("public.html") {
            actions.append(PaletteAction(
                "action.pasteAsHTML",
                systemImage: "chevron.left.forwardslash.chevron.right",
                shortcut: .pasteAsHTML,
                section: .primary
            ) { [weak self] in
                self?.pasteRepresentationSelected(uti: "public.html")
            })
        }
        if utis.contains("public.rtf") {
            actions.append(PaletteAction(
                "action.pasteAsRTF",
                systemImage: "doc.richtext",
                shortcut: .pasteAsRTF,
                section: .primary
            ) { [weak self] in
                self?.pasteRepresentationSelected(uti: "public.rtf")
            })
        }
        return actions
    }

    func copySelected() {
        guard let id = selectedItemID, let item = loadItem(id: id) else { return }
        onCopyRequested?(item)
    }

    func openSelected() {
        guard let id = selectedItemID, let item = loadItem(id: id) else { return }
        switch item.clipType {
        case .url:
            if let url = URL(string: item.content), NSWorkspace.shared.open(url) {
                showNotice(NSLocalizedString("Opening URL.", comment: ""), style: .success)
            } else {
                showNotice(NSLocalizedString("Could not open this URL.", comment: ""), style: .error)
            }
        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            let urls = paths
                .map(URL.init(fileURLWithPath:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else {
                showNotice(NSLocalizedString("No copied files could be found.", comment: ""), style: .error)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            if urls.count < paths.count {
                showNotice(NSLocalizedString("Some files could not be found.", comment: ""), style: .warning)
            } else {
                showNotice(NSLocalizedString("Revealed in Finder.", comment: ""), style: .success)
            }
        default:
            break
        }
    }

    @discardableResult
    func previewSelected() -> Bool {
        guard canPreviewSelectedItem, let selectedItemID else { return false }
        previewTask?.cancel()

        let selectedSnapshot = selectedItem
        let itemsSnapshot = flatOrder
        let core = self.core
        let neighborItemLimit = Self.previewNeighborItemLimit
        isPreparingPreview = true
        previewTask = Task { @MainActor [weak self] in
            let session = await Task.detached(priority: .userInitiated) {
                ClipPreviewResolver.resolveSession(
                    items: itemsSnapshot,
                    selectedItemID: selectedItemID,
                    neighborItemLimit: neighborItemLimit
                ) { id in
                    if selectedSnapshot?.id == id {
                        return selectedSnapshot
                    }
                    return try? core.getItem(id: id)
                }
            }.value

            guard !Task.isCancelled, let self, self.selectedItemID == selectedItemID else { return }
            self.previewTask = nil
            self.isPreparingPreview = false
            guard let session else {
                self.showNotice(NSLocalizedString("Could not preview this item.", comment: ""), style: .error)
                return
            }
            QuickLookPreviewService.shared.present(session: session)
        }
        return true
    }

    func cancelPreviewPreparation() {
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
    }

    func close() { onCloseRequested?() }

    func openSettings() { onOpenSettingsRequested?() }

    func toggleContinuousPaste() {
        isContinuousPasteEnabled.toggle()
        showNotice(
            isContinuousPasteEnabled
                ? NSLocalizedString("Continuous Paste is on. Press Esc to exit.", comment: "")
                : NSLocalizedString("Continuous Paste is off.", comment: ""),
            style: isContinuousPasteEnabled ? .success : .info
        )
    }

    /// Tab 键循环：全部 ↔ 📌 ↔ 文本 ↔ 图片 ↔ 文件 ↔ 链接
    func cycleBrowseMode(reverse: Bool = false) {
        let modes: [LauncherBrowseMode] = [.all, .pinned, .text, .image, .file, .url]
        guard let currentIndex = modes.firstIndex(of: browseMode) else {
            browseMode = .all
            return
        }

        let nextIndex = reverse
            ? (currentIndex - 1 + modes.count) % modes.count
            : (currentIndex + 1) % modes.count
        browseMode = modes[nextIndex]
    }

    @discardableResult
    func clearActiveQueryAndFilters() -> Bool {
        guard hasActiveFilter else { return false }
        skipNextDebouncedLoad = true
        searchQuery = ""
        browseMode = sessionBaseBrowseMode
        loadItems()
        return true
    }

    func prepareForLauncherPresentation(targetAppName: String?, selectLatest: Bool) {
        skipNextDebouncedLoad = true
        sessionBaseBrowseMode = settings.resolvedLaunchBrowseMode()
        searchQuery = ""
        browseMode = sessionBaseBrowseMode
        self.targetAppName = targetAppName
        loadItems(selectLatest: selectLatest)
    }

    func togglePinSelected() {
        guard let selectedItemID else { return }
        togglePin(id: selectedItemID)
    }

    func togglePin(id: String) {
        do {
            let isPinned = try core.togglePin(id: id)
            showNotice(
                isPinned ? NSLocalizedString("Pinned.", comment: "") : NSLocalizedString("Unpinned.", comment: ""),
                style: .success
            )
        } catch {
            showNotice(error.localizedDescription, style: .error)
        }
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

        commitPendingDeletionBeforeReplacing(with: id)

        guard (try? core.getItem(id: id)) != nil else {
            showNotice(NSLocalizedString("Item no longer exists.", comment: ""), style: .error)
            loadItems()
            return
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

        if selectedItemID == id {
            selectedItemID = nextSelectionID
            selectedItem = nil
        }
        pendingDeletion = PendingDeletion(id: id)
        loadItems()

        showNotice(
            NSLocalizedString("Item deleted.", comment: ""),
            style: .warning,
            actionTitle: NSLocalizedString("Undo", comment: ""),
            duration: .seconds(7)
        ) { [weak self] in
            self?.undoPendingDeletion(id: id)
        }

        pendingDeletionTask?.cancel()
        pendingDeletionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(7)) } catch { return }
            self?.commitPendingDeletion(id: id)
        }
    }

    func finalizePendingDeletion() {
        guard let id = pendingDeletion?.id else { return }
        pendingDeletionTask?.cancel()
        commitPendingDeletion(id: id)
    }

    func showNotice(
        _ text: String,
        style: LauncherNoticeStyle = .info,
        actionTitle: String? = nil,
        duration: Duration = .seconds(3),
        action: (() -> Void)? = nil
    ) {
        launcherNotice = LauncherNotice(text: text, style: style, actionTitle: actionTitle)
        noticeAction = action
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            self?.dismissNotice()
        }
    }

    func performNoticeAction() {
        let action = noticeAction
        dismissNotice()
        action?()
    }

    func dismissNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        noticeAction = nil
        launcherNotice = nil
    }

    var selectedListItem: ClipListItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    /// 列表是否为空（用于空状态提示）
    var isEmpty: Bool { flatOrder.isEmpty }

    /// 是否正在搜索或偏离当前会话的默认浏览模式
    var hasActiveFilter: Bool { !searchQuery.isEmpty || browseMode != sessionBaseBrowseMode }

    var isBrowsingFiltered: Bool { browseMode != sessionBaseBrowseMode }

    var canOpenSelectedItem: Bool {
        guard let item = selectedListItem else { return false }
        return item.clipType == .url || item.clipType == .file
    }

    var canPreviewSelectedItem: Bool {
        currentPreviewEntries() != nil
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

    /// 把"取条目 + 可选 touch + 失败时给出用户可见反馈"收口到一处。
    /// 旧实现散落 6 处 `try? core.getItem` 把 SQLite 错误静默吞掉——用户按 Return / ⌘O
    /// 没反应也无反馈，违反 CLAUDE.md "不兜底"原则。所有用户主动触发的取数据动作走此入口。
    /// `currentSelectedItem()` 是只读查询 helper（用于 hint 计算等非动作上下文），仍保留 silent。
    ///
    /// 失败后必须刷新候选集：cleanup / import / 自动清理可能在 DB 删了条目，
    /// 但内存里的 selectedItemID / shortcutOrder 仍指向旧 id。如果不刷新，
    /// 用户连按 Return/⌘O/⌘C 会重复 toast；刷新后 selection 自动落到相邻有效项。
    private func loadItem(id: String, touch: Bool = false) -> ClipItem? {
        do {
            let item = try core.getItem(id: id)
            if touch { try? core.touchItem(id: id) }
            return item
        } catch {
            showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            if selectedItemID == id || shortcutOrder.contains(where: { $0.id == id }) {
                loadItems()
            }
            return nil
        }
    }

    func currentSelectedItem() -> ClipItem? {
        guard let selectedItemID else { return nil }
        if selectedItem?.id == selectedItemID {
            return selectedItem
        }
        return try? core.getItem(id: selectedItemID)
    }

    func syncSelectionToPreviewedClip(id: String) {
        guard selectedItemID != id else { return }
        guard flatOrder.contains(where: { $0.id == id }) else { return }
        selectItem(id: id)
    }

    private func currentPreviewEntries() -> [ClipPreviewEntry]? {
        guard let item = currentSelectedItem() else { return nil }
        return ClipPreviewResolver.resolve(item: item)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    private func rebuildSections() {
        if shouldShowPinnedSection {
            let pinnedItems = items.filter(\.isPinned)
            let regularItems = items.filter { !$0.isPinned }
            var result: [ClipSection] = []
            if !pinnedItems.isEmpty {
                result.append(ClipSection(title: NSLocalizedString("Pinned", comment: ""), items: pinnedItems))
            }
            result.append(contentsOf: Self.makeDateSections(from: regularItems))
            sections = result
        } else {
            sections = Self.makeDateSections(from: items)
        }
        flatOrder = sections.flatMap(\.items)
        shortcutOrder = flatOrder
    }

    /// 搜索永远返回全局结果；浏览态才由 pinned 展示策略决定。
    private func visibleItems(from fetchedItems: [ClipListItem]) -> [ClipListItem] {
        let filtered: [ClipListItem]
        if !searchQuery.isEmpty {
            filtered = fetchedItems
        } else if browseMode.isPinnedOnly {
            filtered = fetchedItems.filter(\.isPinned)
        } else if settings.pinnedItemsPresentation == .pinnedOnlyView {
            filtered = fetchedItems.filter { !$0.isPinned }
        } else {
            filtered = fetchedItems
        }

        guard let pendingDeletion else { return filtered }
        return filtered.filter { $0.id != pendingDeletion.id }
    }

    private var effectiveTypeFilter: ClipType? {
        if searchQuery.isEmpty {
            return browseMode.typeFilter
        }
        return browseMode.isPinnedOnly ? nil : browseMode.typeFilter
    }

    private var shouldShowPinnedSection: Bool {
        guard searchQuery.isEmpty, !browseMode.isPinnedOnly else { return false }
        return settings.pinnedItemsPresentation == .topSection
    }

    /// 当普通浏览选择“仅在 pinned 视图显示”时，分页要以“可见项页”而不是“原始 SQL 页”为准，
    /// 否则第一页可能被隐藏的 pinned 条目吃满，列表会错误显示为空。
    private func fetchBrowsePage(offset: Int, typeFilter: ClipType?) -> (items: [ClipListItem], rawCount: Int, hasMore: Bool) {
        let chunk: [ClipListItem]
        if browseMode.isPinnedOnly {
            chunk = core.getPinnedListItems(
                limit: Int32(Self.pageSize),
                offset: Int32(offset),
                typeFilter: typeFilter
            )
        } else if usesUnpinnedBrowseQuery {
            chunk = core.getUnpinnedListItems(
                limit: Int32(Self.pageSize),
                offset: Int32(offset),
                typeFilter: typeFilter
            )
        } else {
            chunk = core.getListItems(
                limit: Int32(Self.pageSize),
                offset: Int32(offset),
                typeFilter: typeFilter
            )
        }

        return (
            items: visibleItems(from: chunk),
            rawCount: chunk.count,
            hasMore: chunk.count == Self.pageSize
        )
    }

    private var usesUnpinnedBrowseQuery: Bool {
        settings.pinnedItemsPresentation == .pinnedOnlyView
    }

    private func commitPendingDeletionBeforeReplacing(with id: String) {
        guard let pendingID = pendingDeletion?.id, pendingID != id else { return }
        pendingDeletionTask?.cancel()
        commitPendingDeletion(id: pendingID)
    }

    private func commitPendingDeletion(id: String) {
        guard pendingDeletion?.id == id else { return }
        pendingDeletion = nil
        pendingDeletionTask = nil
        do {
            try core.deleteItem(id: id)
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        } catch {
            showNotice(error.localizedDescription, style: .error)
        }
        loadItems()
    }

    private func undoPendingDeletion(id: String) {
        guard pendingDeletion?.id == id else { return }
        pendingDeletionTask?.cancel()
        pendingDeletion = nil
        pendingDeletionTask = nil
        loadItems()
        selectItem(id: id)
        showNotice(NSLocalizedString("Deletion undone.", comment: ""), style: .success)
    }

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
