import AppKit
import Foundation
import SwiftUI
import Combine

struct ClipSection: Identifiable {
    let title: String
    let items: [ClipListItem]
    var id: String { title }
}

enum LauncherNoticeStyle: Equatable {
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

/// launcher 的门面 ViewModel(唯一 ObservableObject)。自洽状态机已抽到独立单元,
/// 本类负责编排它们 + 持有 SwiftUI 渲染态(@Published、selectedItemRevision 判等信号、
/// shortcutIndexByID 等):
///   - ClipSectionBuilder         items → 分组 sections(纯函数)
///   - LauncherNoticeCenter       一次性提示队列 → @Published launcherNotice
///   - LauncherLoadingCoordinator 顶部流光引用计数防闪烁 → @Published isLauncherLoading
///   - PendingDeletionController   7s 可撤销删除 timer(删库副作用由本类注入 commitDeletion)
///   - BrowsePageLoader           分页取数 + pinned 展示策略过滤
/// 渲染拓扑不可动:MainPanel @ObservedObject 全量订阅本类;PreviewPane 刻意不订阅、
/// 靠 selectedItemRevision 判等。改这些会重蹈导航卡顿。
@MainActor
final class ClipboardViewModel: ObservableObject {
    /// `selectedItem` 是"异步加载的完整 payload"，与同步设值的 `selectedItemID` 形成双轨流。
    /// 强制 private(set) 让外部只能通过 `selectItem(id:)` 改变选中状态。
    /// `selectItem` 的完成守卫（`self.selectedItemID == capturedId`）保证：selectedItem 只会被赋值为
    /// 「赋值时仍是当前选中」的条目，绝不会错配成已被翻过的旧项——所以它要么是当前项、要么是上一个
    /// 落定项（连按去抖窗口内），永远不是「左选 A 右显 B」的错配值。
    @Published private(set) var selectedItem: ClipItem? {
        // 每次 selectedItem 赋值即递增 revision。这是「被预览条目变了」的精确单调信号，
        // 供 PreviewPane 的 EquatableView 判等用——避免比较 ClipItem 各字段（易漏字段 / UniFFI
        // 加字段就腐烂）。导航连按时 selectedItem 被去抖压住不赋值 → revision 不变 → 预览整棵跳过重渲染；
        // 落定 / OCR 刷新 / 任何 payload 更新都会赋值 → revision 变 → 预览刷新。
        didSet { selectedItemRevision &+= 1 }
    }
    /// 见 selectedItem.didSet。仅作 PreviewPane 判等信号，不参与业务逻辑。
    @Published private(set) var selectedItemRevision: Int = 0
    @Published var selectedItemID: String?

    /// PreviewPane 等"右侧 payload 消费者"的唯一入口。
    /// 直接返回 selectedItem（不再按 id 严格 gate）：预览与导航解耦后，连按 ↑↓ 的去抖窗口内
    /// selectedItem 刻意滞后停在上一落定项（Finder 式预览滞后），等导航停下再 snap 到落定项。
    /// 此处若仍按 id-gate 返回 nil，窗口内预览会闪空窗 / 转圈圈——正是要消除的卡顿观感。
    /// 错配安全性由 selectedItem 的赋值守卫保证（见上），不需要消费侧再 gate 一道。
    var displayedItem: ClipItem? {
        selectedItem
    }
    @Published var isInTypingMode: Bool = false
    @Published var searchQuery: String = "" {
        didSet { if searchQuery.isEmpty { isInTypingMode = false } }
    }
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
    @Published private(set) var isLauncherLoading = false
    @Published var fileAttachmentPreviewIndex = 0
    @Published private(set) var selectedRepresentationUTIs: [String] = []
    /// 非 nil 表示该 id 的列表行正处于 inline 改名编辑态。
    @Published var renamingItemID: String?
    /// inline 改名 TextField 的草稿文本。独立 ObservableObject，每键不波及共享 VM。
    /// 必须是贯穿全程的单实例(beginRenaming 改写 .text、不重建)——ClipItemRow 的 Equatable
    /// 刻意不比 renameDraft(由 RenameField 自己 @ObservedObject 订阅)。若改成每次改名新建实例,
    /// 该忽略就会变成「打字不刷新行」的真 bug,届时 == 必须改为纳入 draft 身份。
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
    /// 一次性提示队列状态机。lazy:首次访问在 init 之后,self 已完全初始化,[weak self] 安全。
    private lazy var noticeCenter = LauncherNoticeCenter { [weak self] notice in
        self?.launcherNotice = notice
    }
    /// 顶部流光引用计数 + 防闪烁状态机。0.65 = 最小可见时长,避免一闪而过。
    private lazy var loadingCoordinator = LauncherLoadingCoordinator(minimumVisibleSeconds: 0.65) { [weak self] visible in
        self?.isLauncherLoading = visible
    }
    /// 7s 可撤销删除状态机。删库副作用由 commitDeletion 注入。
    private let pendingDeletionController = PendingDeletionController(window: .seconds(7))
    /// 分页取数 + pinned 展示策略过滤。持 core+settings,init 内构造。
    private let browsePageLoader: BrowsePageLoader
    private var items: [ClipListItem] = []
    private var flatOrder: [ClipListItem] = []
    /// ⌘1-9 快捷粘贴序列：始终基于当前可见列表
    private(set) var shortcutOrder: [ClipListItem] = []
    /// 预计算的 id -> ⌘N 序号（1..9），用于行渲染时 O(1) 查找
    /// 之前 view 层每次 body 重渲染都用 prefix(9).enumerated() 重建字典，
    /// 500 条列表上 hover 抖动会触发数百次重建。改成 shortcutOrder 更新时一次性派生。
    private(set) var shortcutIndexByID: [String: Int] = [:]
    private var debounce: AnyCancellable?
    private var ocrSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var loadItemTask: Task<Void, Never>?
    // OCR 静默刷新当前 payload 的任务句柄：必须可被 selectItem 取消，否则 A→B→A 快切时
    // 它会与新 loadItemTask 并发加载同一 id，后完成者把旧快照盖到新结果上。
    private var reloadPayloadTask: Task<Void, Never>?
    private var skipNextDebouncedLoad = false
    private var sessionBaseBrowseMode: LauncherBrowseMode
    private var previewTask: Task<Void, Never>?

    // MARK: - Pagination
    private static let pageSize = 50
    private static let previewNeighborItemLimit = 80
    /// 预览去抖窗口。渲染整棵 PreviewPane 子树会占住主线程（实测：getItem 仅 0.2ms、图片走缩略图
    /// 缓存命中，开销全在 SwiftUI 重渲染），若上在导航关键路径上，会把紧接着的下一次 ↑↓ 按键处理顶到
    /// 后面 → 高亮慢半拍、不跟手。故所有选中一律去抖：selectItem 先睡此窗口，期间又来新选中就取消重来，
    /// 预览只在导航停下那一刻渲染一次，按键路径永远是空的。窗口须大于系统按键连发间隔（实测 ~83ms）
    /// 才能吞掉一次连按里的所有中间项，留足余量取 120ms。
    private static let previewSettleWindow: TimeInterval = 0.12
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
        self.browsePageLoader = BrowsePageLoader(core: core, settings: settings)
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
        // OCR 完成后只刷新当前选中预览：ClipListItem 不含 ocr_text，列表渲染不依赖 OCR；
        // 整个 loadItems 会重建 sections 并打断 selectedItem，反而让用户看到预览闪 ProgressView。
        // 走 reloadSelectedItemPayload 专路：仅在选中图片时重 getItem 拉最新 ocr_text。
        ocrSubscription = NotificationCenter.default
            .publisher(for: .clipboardItemOcrUpdated)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reloadSelectedItemPayload() }
        settingsSubscription = settings.$pinnedItemsPresentation
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.loadItems() }
    }

    // MARK: - Load

    /// 重新加载列表。所有调用方都希望同步关掉打开中的动作面板（避免用户正在选命令时
    /// 列表脚下变化）。OCR 这类「不需要关 palette」的静默刷新已改走 reloadSelectedItemPayload。
    func loadItems(selectLatest: Bool = false) {
        if isShowingActions {
            hideActionsPalette()
        }

        let currentSelectionID = selectLatest ? nil : selectedItemID
        totalLoadedFromDB = 0

        let excludingID = pendingDeletionController.pendingID
        if searchQuery.isEmpty {
            do {
                let page = try browsePageLoader.fetchPage(
                    offset: 0, pageSize: Self.pageSize,
                    query: searchQuery, browseMode: browseMode, excludingID: excludingID)
                items = page.items
                totalLoadedFromDB = page.rawCount
                hasMore = page.hasMore
            } catch {
                ClipinLog.viewModel.error("fetchPage failed: \(error.localizedDescription, privacy: .public)")
                items = []
                totalLoadedFromDB = 0
                hasMore = false
                showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            }
        } else {
            do {
                // Rust 端搜索 SQL/FTS 故障不能 ?? [] 静默退化成"无结果"——用户根本
                // 无法分辨"真的没匹配"和"DB 坏了"。失败时显式 notice，方便察觉异常。
                let results = try core.searchListItems(
                    query: searchQuery,
                    typeFilter: browsePageLoader.effectiveTypeFilter(query: searchQuery, browseMode: browseMode))
                items = browsePageLoader.visible(results, query: searchQuery, browseMode: browseMode, excludingID: excludingID)
            } catch {
                ClipinLog.viewModel.error("searchListItems failed: \(error.localizedDescription, privacy: .public)")
                items = []
                showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            }
            hasMore = false
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

    /// 滚到底时加载下一页，追加到 items 并重建 sections（不重置选中状态）
    func loadMoreItems() {
        guard hasMore, searchQuery.isEmpty else { return }
        let page: BrowsePageLoader.Page
        do {
            page = try browsePageLoader.fetchPage(
                offset: totalLoadedFromDB, pageSize: Self.pageSize,
                query: searchQuery, browseMode: browseMode,
                excludingID: pendingDeletionController.pendingID)
        } catch {
            ClipinLog.viewModel.error("fetchPage(more) failed: \(error.localizedDescription, privacy: .public)")
            showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            hasMore = false
            return
        }
        guard !page.items.isEmpty || page.hasMore else {
            hasMore = false
            return
        }
        // 按 id 去重后再追加：两次翻页之间 DB 可能被改写（粘贴 touchItem 改 created_at、
        // 新复制插入等），offset 语义随之错位，下一页可能与已加载区间重叠。重复 id 一旦
        // 进入 ForEach 就是未定义渲染（旧行视图滞留、选中态残留），必须在数据层挡住。
        let loadedIDs = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !loadedIDs.contains($0.id) })
        totalLoadedFromDB += page.rawCount
        hasMore = page.hasMore
        rebuildSections()
    }

    // MARK: - Selection

    /// 后台异步刷新当前 selectedItem 的完整 payload，不取消 ID 不变的现有 loadItemTask。
    /// 专用于 OCR 完成这类「内容字段更新但选中不变」的通知：让 PreviewPane 拿到新的 ocrText，
    /// 而不打断列表 / 重建 sections / 闪 ProgressView。
    private func reloadSelectedItemPayload() {
        guard let id = selectedItemID,
              selectedItem?.id == id else { return }
        let core = self.core
        reloadPayloadTask?.cancel()
        reloadPayloadTask = Task { [weak self] in
            let refreshed: ClipItem? = await Task.detached(priority: .utility) {
                try? core.getItem(id: id)
            }.value
            guard let self,
                  !Task.isCancelled,
                  let refreshed,
                  self.selectedItemID == id else { return }
            self.selectedItem = refreshed
            self.reloadPayloadTask = nil
        }
    }

    func selectItem(id: String?) {
        loadItemTask?.cancel()
        reloadPayloadTask?.cancel()
        reloadPayloadTask = nil
        previewTask?.cancel()
        previewTask = nil
        isPreparingPreview = false
        loadingCoordinator.clear()
        selectedItemID = id
        guard let id else {
            // 无选中:预览伴随状态立即清空(没有"上一落定项"要维持)。
            fileAttachmentPreviewIndex = 0
            selectedRepresentationUTIs = []
            selectedItem = nil
            return
        }
        // 注意:fileAttachmentPreviewIndex 重置 与 reloadRepresentationsForSelected 都挪到下方「落定」处。
        // 它们是「伴随被预览 item 的状态」,必须和 displayedItem(滞后的 selectedItem)同步,不能跟随
        // 即时的 selectedItemID——否则去抖窗口内会出现「旧内容 + 新格式徽章」「多文件预览瞬间跳回第 1 张」
        // 的错配(Codex 复审实证)。
        // 选中高亮（selectedItemID）已同步更新、底栏走 selectedListItem，导航即时响应。
        // 预览 payload（selectedItem → PreviewPane）的渲染绝不许上导航关键路径：
        // 渲染整棵预览子树会占住主线程，把紧接着的下一次 ↑↓ 按键处理顶到后面 → 高亮慢半拍、不跟手
        //（实测：持续按住时不渲染预览 = 完全跟手；单步走立即渲染 = 卡）。
        // 故所有选中都去抖：先睡 previewSettleWindow，期间又来新选中就取消重来——预览只在你手停下
        // 那一刻渲染一次，按键路径永远是空的。窗口需大于系统连发间隔（实测 ~83ms）才能吞掉连发，取 120ms。
        // 去抖期间 displayedItem 维持上一落定值（完成守卫 selectedItemID==capturedId 杜绝错配），
        // 配合 AsyncPreviewImage 的低清占位，落定渲染时是瞬时清晰、无空窗、无转圈圈。
        let core = self.core
        let capturedId = id
        loadItemTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.previewSettleWindow * 1_000_000_000))
            guard !Task.isCancelled, self.selectedItemID == capturedId else { return }
            // 旧实现用 try? 把 getItem 失败伪装成 selectedItem = nil，预览区悄无声息——
            // 用户连按 Return/⌘O 重复 toast，根本不知道是 DB 故障。失败时显式 notice。
            let result: Result<ClipItem, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try core.getItem(id: capturedId)) }
                catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, self.selectedItemID == capturedId else { return }
            switch result {
            case .success(let item):
                self.selectedItem = item
                // 伴随被预览 item 的状态在「落定」这一刻与它同步刷新(见上方说明):
                // 重置多文件栈到第 1 张、按落定项重查可粘贴格式 UTI。两者都只在预览真正切到新 item
                // 时发生,去抖窗口内维持上一落定项的值,与 displayedItem 一致。
                self.fileAttachmentPreviewIndex = 0
                self.reloadRepresentationsForSelected()
                self.prewarmPreviewNeighbors(around: capturedId)
            case .failure(let error):
                ClipinLog.viewModel.error("selectItem.getItem failed id=\(capturedId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.selectedItem = nil
                self.showNotice(NSLocalizedString("Item could not be read.", comment: ""), style: .error)
            }
        }
    }

    /// 落定某项时，后台预解码相邻图片的预览大图。大图首次落上来要现解码多兆像素原图（最慢 ~100ms），
    /// 用户单步浏览时这段空窗就是「加载慢」的来源。提前在邻居上把解码摊销到用户停留期之外，
    /// 下一步切过去即缓存命中、清晰瞬现。只预热前后各 2 张图片项；解码限并发由 ThumbnailDecodeGate 兜底。
    private func prewarmPreviewNeighbors(around id: String) {
        guard let idx = flatOrder.firstIndex(where: { $0.id == id }) else { return }
        let lo = max(0, idx - 2)
        let hi = min(flatOrder.count - 1, idx + 2)
        let paths: [String] = (lo...hi).compactMap { i in
            guard i != idx else { return nil }  // 当前项由 AsyncPreviewImage 自己解码，不重复
            let item = flatOrder[i]
            guard item.clipType == .image, let path = item.imagePath else { return nil }
            return path
        }
        for path in paths {
            Task.detached(priority: .utility) {
                _ = await ClipImageThumbnailCache.preview.thumbnail(for: path)
            }
        }
    }

    func setPreviewNetworkLoading(_ isLoading: Bool, key: String) {
        loadingCoordinator.set(isLoading, source: .previewNetwork(key))
    }

    func reloadRepresentationsForSelected() {
        guard let id = selectedItemID else {
            selectedRepresentationUTIs = []
            return
        }
        // 选中导航与「格式数据加载」解耦：只有 text / url 才有可粘贴的富文本格式（HTML / RTF），
        // 其余类型（图片 / 文件）没有这层动作，直接清空、连查询都不发。图片的 representations 是
        // 数十 MB 的无压缩 TIFF/PNG，高频上下选中时若为拿格式名而读它，就是大图卡顿的根因。
        guard let clipType = selectedListItem?.clipType, clipType == .text || clipType == .url else {
            selectedRepresentationUTIs = []
            return
        }
        let core = self.core
        Task.detached(priority: .userInitiated) { [weak self] in
            // 只查 UTI 列表、不读 data BLOB（getRepresentationUtis vs getRepresentations）：
            // 选中只需知道「有哪些格式」，data 留到真正 ⌥H/⌥R 粘贴时由 performPasteRepresentation 按需读。
            // 旧实现 ?? [] 把失败伪装成"没有 rich format"，按"不兜底"显式 log；失败清空（保留旧的会串格式）。
            let result: Result<[String], Error>
            do { result = .success(try core.getRepresentationUtis(id: id)) }
            catch { result = .failure(error) }
            await MainActor.run {
                guard let self else { return }
                guard self.selectedItemID == id else { return }
                switch result {
                case .success(let utis):
                    self.selectedRepresentationUTIs = utis
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

    /// Home：跳到当前已加载列表的首条（最新）。
    func selectFirst() {
        guard !flatOrder.isEmpty else { return }
        selectItem(id: flatOrder.first?.id)
    }

    /// End：跳到当前已加载列表的末条。受分页约束，到的是「已加载」末条而非 DB 绝对末条，
    /// 与 loadMoreItems 的分页语义一致——继续 End/↓ 触底会拉下一页。
    func selectLast() {
        guard !flatOrder.isEmpty else { return }
        selectItem(id: flatOrder.last?.id)
    }

    /// PageUp/PageDown：按整页步进跳选，介于单行 ↑↓ 与 Home/End 跳首尾之间。
    /// 无选中时 delta>0 落到首条、delta<0 落到末条（与 selectNext/selectPrev 的兜底方向一致）。
    func selectByPage(_ delta: Int) {
        guard !flatOrder.isEmpty else { return }
        let pageStep = 10
        guard let currentID = selectedItemID,
              let idx = flatOrder.firstIndex(where: { $0.id == currentID }) else {
            selectItem(id: (delta > 0 ? flatOrder.first : flatOrder.last)?.id)
            return
        }
        let target = min(max(idx + delta * pageStep, 0), flatOrder.count - 1)
        selectItem(id: flatOrder[target].id)
    }

    @discardableResult
    func stepFileAttachmentPreview(delta: Int) -> Bool {
        guard let item = displayedItem, item.clipType == .file else { return false }
        // 步进覆盖所有文件,不仅图片:Raycast 风格叠放卡可同时展示图片缩略图和文件 icon,
        // 用户预期 ←→ 走遍整组(否则混合复制时只能切到图,DMG/ZIP 反而切不到,语义割裂)。
        let count = FileClipboardContent.paths(from: item.content).count
        guard count > 1 else { return false }
        // 循环切换:最后一张 → 第一张,反向同理。Swift `%` 对负数返回负数(不同 Python),
        // 必须 ((x % n) + n) % n 双取余才能把"向左从 0 翻到末尾"算对。
        let next = ((fileAttachmentPreviewIndex + delta) % count + count) % count
        guard next != fileAttachmentPreviewIndex else { return true }
        fileAttachmentPreviewIndex = next
        return true
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
        loadingCoordinator.set(true, source: .quickLookPreparation)
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
            self.loadingCoordinator.set(false, source: .quickLookPreparation)
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
        loadingCoordinator.set(false, source: .quickLookPreparation)
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
    /// 搜索态剔除 .pinned：搜索时 pinned 被 LauncherSearchScope 降级显示为 .all
    /// （搜索是全局召回，pinned 只是浏览视图），若仍留在循环里会出现「all→pinned」
    /// 视觉零变化的空转一档，用户感知为「按了 Tab 没反应」。
    func cycleBrowseMode(reverse: Bool = false) {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modes: [LauncherBrowseMode] = isSearching
            ? [.all, .text, .image, .file, .url]
            : [.all, .pinned, .text, .image, .file, .url]
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

        pendingDeletionController.commitOther(than: id)

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
        // arm 在 loadItems 前:loadItems → visibleItems 要靠 controller.pendingID 把待删项滤掉。
        pendingDeletionController.arm(id: id) { [weak self] in
            self?.commitDeletion(id: id)
        }
        loadItems()

        showNotice(
            NSLocalizedString("Item deleted.", comment: ""),
            style: .warning,
            actionTitle: NSLocalizedString("Undo", comment: ""),
            duration: .seconds(7)
        ) { [weak self] in
            self?.undoPendingDeletion(id: id)
        }
    }

    func finalizePendingDeletion() {
        pendingDeletionController.commitNow()
    }

    func showNotice(
        _ text: String,
        style: LauncherNoticeStyle = .info,
        actionTitle: String? = nil,
        duration: Duration = .seconds(3),
        action: (() -> Void)? = nil
    ) {
        noticeCenter.show(text, style: style, actionTitle: actionTitle, duration: duration, action: action)
    }

    func performNoticeAction() {
        noticeCenter.performAction()
    }

    func dismissNotice() {
        noticeCenter.dismiss()
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

    private func rebuildSections() {
        sections = ClipSectionBuilder.build(
            items: items,
            showPinnedSection: browsePageLoader.shouldShowPinnedSection(query: searchQuery, browseMode: browseMode))
        flatOrder = sections.flatMap(\.items)
        shortcutOrder = flatOrder
        shortcutIndexByID = Dictionary(
            uniqueKeysWithValues: shortcutOrder.prefix(9).enumerated().map { ($1.id, $0 + 1) }
        )
    }

    /// 真正删库 + 广播 + 刷新。由 pendingDeletionController 到点(或 commitNow/commitOther)
    /// 触发的注入 closure 调用;失败显式 notice,不静默吞。
    private func commitDeletion(id: String) {
        do {
            try core.deleteItem(id: id)
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
        } catch {
            showNotice(error.localizedDescription, style: .error)
        }
        loadItems()
    }

    private func undoPendingDeletion(id: String) {
        guard pendingDeletionController.pendingID == id else { return }
        pendingDeletionController.cancel()
        loadItems()
        selectItem(id: id)
        showNotice(NSLocalizedString("Deletion undone.", comment: ""), style: .success)
    }
}
