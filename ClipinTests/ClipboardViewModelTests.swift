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
            createdAt: 1_000
        )
        let newer = try core.importItem(
            content: "newer",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil,
            isPinned: false,
            createdAt: 2_000
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

    func testSilentReloadCanPreserveActionPalette() throws {
        let core = try makeCore()
        _ = try core.saveItem(
            content: "keep actions open",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let viewModel = ClipboardViewModel(core: core)
        viewModel.loadItems(selectLatest: true)
        viewModel.showActionsPalette()

        XCTAssertTrue(viewModel.isShowingActions)

        viewModel.loadItems(hidesActions: false)

        XCTAssertTrue(viewModel.isShowingActions)
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
                createdAt: Int64(2_000 + index)
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
                createdAt: Int64(1_000 + index)
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
                createdAt: Int64(1_000 + index)
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
