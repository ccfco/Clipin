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
}
