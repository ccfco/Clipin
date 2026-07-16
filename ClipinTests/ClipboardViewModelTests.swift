import XCTest
@testable import Clipin

@MainActor
final class ClipboardViewModelTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    func testDeleteCanBeUndoneBeforePendingDeletionCommits() throws {
        let core = try makeCore()
        let item = try core.saveItem(
            content: "undo me",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        viewModel.deleteItem(id: item.id)

        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(try core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 1)
        XCTAssertEqual(viewModel.launcherNotice?.actionTitle, NSLocalizedString("Undo", comment: ""))

        viewModel.performNoticeAction()

        XCTAssertFalse(viewModel.isEmpty)
        XCTAssertEqual(viewModel.selectedItemID, item.id)
        XCTAssertEqual(try core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 1)
    }

    func testFinalizePendingDeletionRemovesItemFromStorage() throws {
        let core = try makeCore()
        let item = try core.saveItem(
            content: "delete me",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        viewModel.deleteItem(id: item.id)
        viewModel.finalizePendingDeletion()

        XCTAssertTrue(viewModel.isEmpty)
        XCTAssertEqual(try core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 0)
    }

    func testQuickPasteTouchesItemSoItBecomesRecent() throws {
        let core = try makeCore()
        let older = try core.importItem(
            content: "older",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil,
            isPinned: false,
            createdAt: 1_000,
            alias: nil
        )
        let newer = try core.importItem(
            content: "newer",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil,
            isPinned: false,
            createdAt: 2_000,
            alias: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        XCTAssertEqual(viewModel.shortcutOrder.map(\.id), [newer.id, older.id])

        var pastedID: String?
        viewModel.onPasteRequested = { pastedID = $0.id }
        viewModel.pasteItemAt(index: 1)

        XCTAssertEqual(pastedID, older.id)
        XCTAssertEqual(try core.getItems(limit: 10, offset: 0, typeFilter: nil).first?.id, older.id)
    }

    // 1707b0a 后语义：loadItems 总是关 palette；OCR 这类「不需要关」的静默刷新走
    // .clipboardItemOcrUpdated → reloadSelectedItemPayload 专路。
    // reloadSelectedItemPayload 是 private，只能经通知路径间接触发。
    func testSilentReloadCanPreserveActionPalette() async throws {
        let core = try makeCore()
        _ = try core.saveItem(
            content: "ocr-row",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        viewModel.showActionsPalette()
        XCTAssertTrue(viewModel.isShowingActions, "Precondition: palette must be open before posting OCR notification")

        NotificationCenter.default.post(name: .clipboardItemOcrUpdated, object: nil)

        // 订阅链 `.receive(on: RunLoop.main).sink` 会把回调推到下一个 runloop tick；
        // 给一小段时间让 sink 跑完，避免断言早于订阅闭包执行。
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(viewModel.isShowingActions, "OCR-completed notification must not close the action palette")
    }

    func testPinnedOnlyPresentationLoadsHiddenRegularItemsWithoutSkippingOverflow() throws {
        let previousPresentation = SettingsStore.shared.pinnedItemsPresentation
        SettingsStore.shared.pinnedItemsPresentation = .pinnedOnlyView
        defer { SettingsStore.shared.pinnedItemsPresentation = previousPresentation }

        let core = try makeCore()
        for index in 0..<51 {
            _ = try core.importItem(
                content: "pinned-\(index)",
                clipType: .text,
                sourceApp: nil,
                sourceName: nil,
                imagePath: nil,
                isPinned: true,
                createdAt: Int64(2_000 + index),
                alias: nil
            )
        }
        for index in 0..<60 {
            _ = try core.importItem(
                content: "regular-\(index)",
                clipType: .text,
                sourceApp: nil,
                sourceName: nil,
                imagePath: nil,
                isPinned: false,
                createdAt: Int64(1_000 + index),
                alias: nil
            )
        }

        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        XCTAssertEqual(visibleContents(in: viewModel).count, 50)
        XCTAssertTrue(viewModel.hasMore)

        viewModel.loadMoreItems()

        let visible = visibleContents(in: viewModel)
        XCTAssertEqual(visible.count, 60)
        XCTAssertEqual(Set(visible).count, 60)
        XCTAssertTrue(visible.allSatisfy { $0.hasPrefix("regular-") })
        XCTAssertFalse(viewModel.hasMore)
    }

    func testPinnedBrowseModeCanLoadMoreThanFirstPage() throws {
        let core = try makeCore()
        for index in 0..<60 {
            _ = try core.importItem(
                content: "pinned-\(index)",
                clipType: .text,
                sourceApp: nil,
                sourceName: nil,
                imagePath: nil,
                isPinned: true,
                createdAt: Int64(1_000 + index),
                alias: nil
            )
        }

        let viewModel = ClipboardViewModel(core: core)
        viewModel.browseMode = .pinned
        viewModel.loadItems(selectLatest: true)

        XCTAssertEqual(visibleContents(in: viewModel).count, 50)
        XCTAssertTrue(viewModel.hasMore)

        viewModel.loadMoreItems()

        XCTAssertEqual(visibleContents(in: viewModel).count, 60)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testLoadMoreDeduplicatesWhenDBShiftedBetweenPages() throws {
        // 翻页间隙 DB 被改写(新复制插入顶部/粘贴 touch 改 created_at)会让 OFFSET 语义错位,
        // 下一页与已加载区间重叠。重复 id 一旦进 SwiftUI ForEach 就是未定义渲染
        // (旧行视图滞留成"选中态残留"),loadMoreItems 必须按已有 id 去重。
        let core = try makeCore()
        for index in 0..<60 {
            _ = try core.importItem(
                content: "item-\(index)",
                clipType: .text,
                sourceApp: nil,
                sourceName: nil,
                imagePath: nil,
                isPinned: false,
                createdAt: Int64(1_000 + index),
                alias: nil
            )
        }

        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)
        XCTAssertEqual(visibleIDs(in: viewModel).count, 50)
        XCTAssertTrue(viewModel.hasMore)

        // 模拟翻页间隙的新复制:插入 1 条最新条目,所有旧条目 offset 后移 1,
        // 下一页(offset=50)的第一条就是已加载的旧第 50 条——制造确定性重叠。
        _ = try core.importItem(
            content: "new-arrival",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil,
            isPinned: false,
            createdAt: 9_000,
            alias: nil
        )

        viewModel.loadMoreItems()

        let ids = visibleIDs(in: viewModel)
        XCTAssertEqual(Set(ids).count, ids.count, "翻页拼接后不允许出现重复 id")
    }

    func testPrepareForLauncherPresentationBumpsGenerationAndLiftsGate() throws {
        // 世代 identity 是"中毒 cell"（残留行）的恢复机制:每次 showPanel 必须 +1 让 MainPanel
        // 整树重建;同时必须先解除隐藏门禁再 loadItems,否则打开面板时列表是空的。
        let core = try makeCore()
        _ = try core.saveItem(
            content: "present me",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        let initialGeneration = viewModel.presentationGeneration

        viewModel.isLauncherPresented = false
        viewModel.prepareForLauncherPresentation(targetApp: nil, selectLatest: true)

        XCTAssertEqual(viewModel.presentationGeneration, initialGeneration + 1)
        XCTAssertTrue(viewModel.isLauncherPresented)
        XCTAssertFalse(viewModel.isEmpty, "解除门禁后 loadItems 必须真的取到数据")

        viewModel.prepareForLauncherPresentation(targetApp: nil, selectLatest: true)
        XCTAssertEqual(viewModel.presentationGeneration, initialGeneration + 2)
    }

    func testLauncherLoadingTracksCurrentPreviewNetworkRequest() async throws {
        let viewModel = ClipboardViewModel(core: try makeCore())

        XCTAssertFalse(viewModel.isLauncherLoading)

        viewModel.setPreviewNetworkLoading(true, key: "old-url")
        XCTAssertTrue(viewModel.isLauncherLoading)

        viewModel.setPreviewNetworkLoading(true, key: "new-url")
        viewModel.setPreviewNetworkLoading(false, key: "old-url")
        XCTAssertTrue(viewModel.isLauncherLoading, "A stale URL task must not clear the current loading indicator")

        viewModel.setPreviewNetworkLoading(false, key: "new-url")
        XCTAssertTrue(viewModel.isLauncherLoading, "The loading indicator should stay visible long enough to be perceived")

        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(viewModel.isLauncherLoading)
    }

    // 选中条目走的是本地 SQLite getItem（瞬时），不该点亮给「真异步加载」（网络预览 / Quick Look
    // 准备）用的顶部流光。否则 ↑↓ 连按时，每次选中都点亮流光 + 0.65s 最小可见时长把它钉成
    // 持续 TimelineView(.animation) 每帧重绘，拖卡键盘导航。流光只能由真正慢的异步源驱动。
    func testSelectingItemDoesNotShowLauncherLoadingForLocalRead() throws {
        let core = try makeCore()
        _ = try core.importItem(
            content: "local",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil,
            isPinned: false,
            createdAt: 1_000,
            alias: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)

        XCTAssertNotNil(viewModel.selectedItemID, "loadItems(selectLatest:) 应已选中最新条目")
        XCTAssertFalse(viewModel.isLauncherLoading, "本地读不该点亮顶部流光")
    }

    private func makeCore() throws -> ClipinCore {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinViewModelTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)

        return try ClipinCore(
            dbPath: rootURL.appendingPathComponent("test.db").path,
            imageDir: imageURL.path
        )
    }

    private func visibleContents(in viewModel: ClipboardViewModel) -> [String] {
        viewModel.sections.flatMap(\.items).map(\.preview)
    }

    private func visibleIDs(in viewModel: ClipboardViewModel) -> [String] {
        viewModel.sections.flatMap(\.items).map(\.id)
    }
}
