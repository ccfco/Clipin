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
        XCTAssertEqual(core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 1)
        XCTAssertEqual(viewModel.launcherNotice?.actionTitle, NSLocalizedString("Undo", comment: ""))

        viewModel.performNoticeAction()

        XCTAssertFalse(viewModel.isEmpty)
        XCTAssertEqual(viewModel.selectedItemID, item.id)
        XCTAssertEqual(core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 1)
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
        XCTAssertEqual(core.getItems(limit: 10, offset: 0, typeFilter: nil).count, 0)
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
}
