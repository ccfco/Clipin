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

/// 仅承载 inline 改名 / 内容编辑的高频草稿文本。单独成一个 ObservableObject——
/// 草稿每次按键都变，若挂在共享的 ClipboardViewModel 上，经典 @Published 的全量
/// objectWillChange 会让整列 ClipItemRow + PreviewPane 每键重渲染。只有正在编辑的
/// 那个小控件订阅它，打字时其余视图完全不动。
final class EditingDraft: ObservableObject {
    @Published var text: String = ""
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
    /// 目标 App 图标,供动作面板 Paste 行渲染真实 App 图标(对齐 Raycast)。
    /// 与 targetAppName 同源同步更新,统一走 updateTargetApp(_:)。
    @Published var targetAppIcon: NSImage?
    @Published var isShowingActions = false
    @Published var selectedActionIndex = 0
    @Published private(set) var paletteActions: [PaletteAction] = []
    @Published var isContinuousPasteEnabled: Bool = false
    /// 是否显示 ⌘1-9 快速粘贴数字提示。由 AppDelegate 在用户「长按 ⌘」
    /// 达到阈值后置 true、松开或离开面板时置 false,驱动 Raycast 式 hold-to-reveal。
    @Published var isShortcutHintVisible: Bool = false
    @Published private(set) var launcherNotice: LauncherNotice?
    @Published private(set) var isPreparingPreview = false
    @Published private(set) var selectedRepresentationUTIs: [String] = []
    /// 非 nil 表示该 id 的列表行正处于 inline 改名编辑态。
    @Published var renamingItemID: String?
    /// inline 改名 TextField 的草稿文本。独立 ObservableObject，每键不波及共享 VM。
    let renameDraft = EditingDraft()
    /// beginRenaming 时记录的预填值。commitRenaming 用它判断用户是否真的改了名，
    /// 避免「打开 rename 又直接点走（失焦自动提交）」把派生标题误写成 alias。
    private var renameBaseline: String = ""
    /// 非 nil 表示该 id 的条目正处于 preview 区内容编辑态。
    @Published var editingContentItemID: String?
    /// Edit Content TextEditor 的草稿文本。独立 ObservableObject，每键不波及共享 VM。
    let editingContentDraft = EditingDraft()
    /// 「粘贴为…」子面板:非空即子面板显示中。
    @Published private(set) var subPaletteActions: [PaletteAction] = []
    @Published var selectedSubActionIndex: Int = 0
    var isShowingSubPalette: Bool { !subPaletteActions.isEmpty }

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
        // 带 submenu 的动作:激活 = 打开子面板,不执行 handler、不关闭命令面板。
        if let submenu = action.submenu {
            openSubPalette(submenu)
            return
        }
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
        guard isShowingActions else { return false }
        // 子面板打开时,快捷键只在子面板范围内匹配——主面板的 ⌘O/⌘C/Space 等
        // 不应穿透到子面板执行,否则键盘焦点没有真正收束到子面板。
        // 主面板态:representation 动作收进了「粘贴为…」submenu,匹配需穿透 submenu,
        // 让 ⇧↵/⌥H/⌥R 在命令面板打开时仍能直接命中。
        let scope: [PaletteAction] = isShowingSubPalette
            ? subPaletteActions
            : paletteActions.flatMap { [$0] + ($0.submenu ?? []) }
        guard let action = scope.first(where: { $0.shortcut == shortcut }) else {
            return false
        }
        action.handler()
        hideActionsPalette(restoreFocus: action.restoresSearchFocus)
        return true
    }

    // MARK: - 「粘贴为…」子面板

    func openSubPalette(_ actions: [PaletteAction]) {
        guard !actions.isEmpty else { return }
        selectedSubActionIndex = 0
        withAnimation(ClipinMotion.paletteReveal) {
            subPaletteActions = actions
        }
    }

    func closeSubPalette() {
        withAnimation(ClipinMotion.paletteDismiss) {
            subPaletteActions = []
        }
        selectedSubActionIndex = 0
    }

    func navigateSubPalette(delta: Int) {
        let count = subPaletteActions.count
        guard count > 0 else { return }
        selectedSubActionIndex = (selectedSubActionIndex + delta + count) % count
    }

    func executeSelectedSubPaletteAction() {
        executeSubPaletteAction(at: selectedSubActionIndex)
    }

    func executeSubPaletteAction(at index: Int) {
        guard index >= 0, index < subPaletteActions.count else { return }
        let action = subPaletteActions[index]
        action.handler()
        hideActionsPalette(restoreFocus: action.restoresSearchFocus)
    }

    func toggleActionsPalette() {
        isShowingActions ? hideActionsPalette(restoreFocus: true) : showActionsPalette()
    }

    func showActionsPalette() {
        let actions = ActionPaletteBuilder.actions(for: self)
        guard !actions.isEmpty else { return }
        paletteActions = actions
        selectedActionIndex = min(selectedActionIndex, max(actions.count - 1, 0))
        withAnimation(ClipinMotion.paletteReveal) {
            isShowingActions = true
        }
    }

    func hideActionsPalette(restoreFocus: Bool = false) {
        withAnimation(ClipinMotion.paletteDismiss) {
            isShowingActions = false
        }
        paletteActions = []
        selectedActionIndex = 0
        subPaletteActions = []
        selectedSubActionIndex = 0

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
            do {
                items = try core.searchListItems(query: searchQuery, typeFilter: typeFilter)
            } catch {
                // Rust 端搜索 SQL/FTS 故障不能 ?? [] 静默退化成"无结果"——用户根本
                // 无法分辨"真的没匹配"和"DB 坏了"。失败时显式 notice，方便察觉异常
                // （修改自 storage::search 返回 Result 的改造）。
                ClipinLog.viewModel.error("searchListItems failed: \(error.localizedDescription, privacy: .public)")
                items = []
                showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            }
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
        // 主线程立即更新 ID（选中高亮即时响应），后台加载完整 item（避免 SQLite 阻塞主线程）。
        // 旧实现用 try? 把 getItem 失败伪装成 selectedItem = nil，预览区悄无声息——
        // 用户连按 Return/⌘O 重复 toast，根本不知道是 DB 故障。失败时显式 notice。
        let core = self.core
        let capturedId = id
        loadItemTask = Task {
            let result: Result<ClipItem, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try core.getItem(id: capturedId)) }
                catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, self.selectedItemID == capturedId else { return }
            switch result {
            case .success(let item):
                self.selectedItem = item
            case .failure(let error):
                ClipinLog.viewModel.error("selectItem.getItem failed id=\(capturedId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.selectedItem = nil
                self.showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            }
        }
    }

    func reloadRepresentationsForSelected() {
        guard let id = selectedItemID else {
            selectedRepresentationUTIs = []
            return
        }
        let core = self.core
        Task.detached(priority: .userInitiated) { [weak self] in
            // 旧实现 ?? [] 把 representations 加载失败伪装成"没有 rich format"，
            // 用户在 footer 看不到 HTML/RTF 选项不知道是 DB 故障——按"不兜底"显式 log，
            // 失败时清空 UTI 集合（保留旧的会让别的条目显示错的格式）。
            let result: Result<[ClipRepresentation], Error>
            do { result = .success(try core.getRepresentations(id: id)) }
            catch { result = .failure(error) }
            await MainActor.run {
                guard let self else { return }
                guard self.selectedItemID == id else { return }
                switch result {
                case .success(let reps):
                    self.selectedRepresentationUTIs = reps.map { $0.uti }
                case .failure(let error):
                    ClipinLog.viewModel.error("reloadRepresentationsForSelected failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    self.selectedRepresentationUTIs = []
                }
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

    // MARK: - Rename

    /// 进入 inline 改名编辑态。预填该行当前显示名 displayTitle
    /// （别名优先；无别名时是按类型推导的标题：text/url 取内容首行、image 取来源+尺寸、file 取文件标题）。
    func beginRenaming(id: String) {
        guard let listItem = items.first(where: { $0.id == id }) else { return }
        if isShowingActions { hideActionsPalette() }
        cancelEditContent()        // 两个编辑态互斥
        // 预填用 displayTitle 而非 preview：preview 对 image/file 是 OCR/路径原文，
        // 拿来当改名预填毫无意义；displayTitle 才是用户当前在列表里看到的那行字。
        renameDraft.text = listItem.displayTitle
        renameBaseline = listItem.displayTitle
        renamingItemID = id
    }

    /// 对当前选中项进入 inline 改名编辑态（主面板 ⇧⌘E 直达，无需先开 ⌘K）。无选中项则忽略。
    func beginRenamingSelected() {
        guard let id = selectedListItem?.id else { return }
        beginRenaming(id: id)
    }

    /// 提交别名。空字符串清空别名；非空写入。提交后刷新列表。
    /// 用户没动过预填文字（如打开 rename 又直接点走触发失焦提交）则不写库——
    /// 否则会把无别名条目的派生标题持久化成 alias，凭空「命名」了它。
    func commitRenaming() {
        guard let id = renamingItemID else { return }
        let trimmed = renameDraft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = renameDraft.text == renameBaseline
        renamingItemID = nil
        renameDraft.text = ""
        renameBaseline = ""
        guard !unchanged else { return }
        do {
            try core.setAlias(id: id, alias: trimmed.isEmpty ? nil : trimmed)
            loadItems()
            showNotice(NSLocalizedString("Renamed.", comment: ""), style: .success)
        } catch {
            ClipinLog.viewModel.error("setAlias failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showNotice(NSLocalizedString("Could not rename this item.", comment: ""), style: .error)
        }
    }

    /// 放弃改名，不写库。
    func cancelRenaming() {
        renamingItemID = nil
        renameDraft.text = ""
        renameBaseline = ""
    }

    // MARK: - Edit Content

    /// 进入 preview 区内容编辑态。仅 text/url 类型可编辑。
    func beginEditContent(id: String) {
        guard let listItem = items.first(where: { $0.id == id }) else { return }
        guard listItem.clipType == .text || listItem.clipType == .url else {
            // 主面板 ⌘E 可落在图片/文件条目上；静默 return 会让用户不知为何无反应。
            showNotice(
                NSLocalizedString("Only text and links support content editing.", comment: ""),
                style: .info
            )
            return
        }
        if isShowingActions { hideActionsPalette() }
        cancelRenaming()           // 两个编辑态互斥
        guard let full = loadItem(id: id) else { return }
        editingContentDraft.text = full.content
        editingContentItemID = id
    }

    /// 对当前选中项进入内容编辑态（主面板 ⌘E 直达，无需先开 ⌘K）。
    /// 无选中项、或选中项非 text/url 时静默忽略（beginEditContent 内部已校验类型）。
    func beginEditContentSelected() {
        guard let id = selectedListItem?.id else { return }
        beginEditContent(id: id)
    }

    /// 提交编辑后的内容。依据新内容重新判定类型，提交后刷新。
    func commitEditContent() {
        guard let id = editingContentItemID else { return }
        let newContent = editingContentDraft.text
        let probe = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // 内容清空再保存会落库一条无意义的空条目；拦截并保留编辑器，让用户改回或 Esc 取消。
        guard !probe.isEmpty else {
            showNotice(NSLocalizedString("Content can't be empty.", comment: ""), style: .warning)
            return
        }
        // URL 类型落库存 trim 后内容：类型判定与保存口径必须一致，否则带首尾空白的
        // URL 会被存成 .url，但后续「打开 URL / 预览」的 URL(string:) 会因空白解析失败。
        // 文本类型保留用户原样输入。
        let newType: ClipType
        let contentToSave: String
        if let url = ClipboardMonitor.httpURLString(in: probe) {
            newType = .url
            contentToSave = url
        } else {
            newType = .text
            contentToSave = newContent
        }
        do {
            try core.updateContent(id: id, newContent: contentToSave, newType: newType)
            // 写库成功后才退出编辑态——失败时保留 draft 与编辑器，用户输入不丢、可重试。
            editingContentItemID = nil
            editingContentDraft.text = ""
            loadItems()
            showNotice(NSLocalizedString("Content saved.", comment: ""), style: .success)
        } catch {
            ClipinLog.viewModel.error("updateContent failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showNotice(NSLocalizedString("Could not save content.", comment: ""), style: .error)
        }
    }

    /// 放弃内容编辑，不写库。
    func cancelEditContent() {
        editingContentItemID = nil
        editingContentDraft.text = ""
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
            // 旧实现用 Task.detached 切断了结构化 cancellation 链——外层 previewTask.cancel()
            // 只会让 wrapper 抛 CancellationError，detached 内的 resolveSession 仍然继续扫
            // 邻近 item，旧 session 后台跑完才丢弃。改成 withTaskGroup 后 cancel 沿子任务下传，
            // closure 内 Task.isCancelled 检查能在邻近 item 之间短路。
            let session = await withTaskGroup(of: ClipPreviewSession?.self) { group in
                group.addTask(priority: .userInitiated) {
                    ClipPreviewResolver.resolveSession(
                        items: itemsSnapshot,
                        selectedItemID: selectedItemID,
                        neighborItemLimit: neighborItemLimit
                    ) { id in
                        if Task.isCancelled { return nil }
                        if selectedSnapshot?.id == id {
                            return selectedSnapshot
                        }
                        // Quick Look 的"邻近条目"语义允许 partial（被删/损坏时少几项可接受），
                        // 但失败仍要 log——之前裸 try? 静默丢弃无法反查根因。
                        // 当前选中项失败由外层 session == nil 分支显式 notice。
                        do { return try core.getItem(id: id) }
                        catch {
                            ClipinLog.viewModel.error("preview neighbor getItem failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                            return nil
                        }
                    }
                }
                return await group.next() ?? nil
            }

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

    func prepareForLauncherPresentation(targetApp: NSRunningApplication?, selectLatest: Bool) {
        skipNextDebouncedLoad = true
        sessionBaseBrowseMode = settings.resolvedLaunchBrowseMode()
        searchQuery = ""
        browseMode = sessionBaseBrowseMode
        updateTargetApp(targetApp)
        loadItems(selectLatest: selectLatest)
    }

    /// 目标 App 名与图标的唯一写入口,保证二者同源不漂移。
    func updateTargetApp(_ app: NSRunningApplication?) {
        targetAppName = app?.localizedName
        targetAppIcon = app?.icon
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
            if touch {
                // touchItem 失败只影响"最近使用"排序，不能阻断已经成功取到的粘贴主流程；
                // 但也不能 try? 静默吞掉——至少打到 stderr，方便后续从日志反查排序异常。
                do { try core.touchItem(id: id) } catch {
                    ClipinLog.viewModel.error("touchItem failed id=\(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
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

    /// section 标题用的简短月日格式。旧实现硬编码 "M月d日"，英文环境也会显示中文，
    /// 违反 "用户可见文案走本地化" 约束。改用 dateFormat(fromTemplate:) 让 macOS 按当前
    /// locale 自动选择合适的 month/day 排序（en: "May 20", zh: "5月20日"）。
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("Md")
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
    ///
    /// Rust 端 get_(pinned|unpinned)_list_items 现在返回 Result（旧实现把 SQL/decode 失败
    /// unwrap_or_default 伪装成"空历史"，违反 CLAUDE.md "不兜底"）。失败时返回空 chunk +
    /// 关闭分页 + showNotice，让用户知道 DB 故障而非"真的没数据"。
    private func fetchBrowsePage(offset: Int, typeFilter: ClipType?) -> (items: [ClipListItem], rawCount: Int, hasMore: Bool) {
        let chunk: [ClipListItem]
        do {
            if browseMode.isPinnedOnly {
                chunk = try core.getPinnedListItems(
                    limit: Int32(Self.pageSize),
                    offset: Int32(offset),
                    typeFilter: typeFilter
                )
            } else if usesUnpinnedBrowseQuery {
                chunk = try core.getUnpinnedListItems(
                    limit: Int32(Self.pageSize),
                    offset: Int32(offset),
                    typeFilter: typeFilter
                )
            } else {
                chunk = try core.getListItems(
                    limit: Int32(Self.pageSize),
                    offset: Int32(offset),
                    typeFilter: typeFilter
                )
            }
        } catch {
            ClipinLog.viewModel.error("fetchBrowsePage failed offset=\(offset, privacy: .public): \(error.localizedDescription, privacy: .public)")
            showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            return (items: [], rawCount: 0, hasMore: false)
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
