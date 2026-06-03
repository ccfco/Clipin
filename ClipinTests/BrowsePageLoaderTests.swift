import XCTest
@testable import Clipin

@MainActor
final class BrowsePageLoaderTests: XCTestCase {
    private var tempRoots: [URL] = []
    override func tearDown() {
        for root in tempRoots { try? FileManager.default.removeItem(at: root) }
        tempRoots.removeAll()
        super.tearDown()
    }
    private func makeCore() throws -> ClipinCore {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowsePageLoaderTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)
        return try ClipinCore(dbPath: rootURL.appendingPathComponent("test.db").path, imageDir: imageURL.path)
    }
    private func loader() throws -> BrowsePageLoader {
        BrowsePageLoader(core: try makeCore(), settings: .shared)
    }
    private func item(_ id: String, isPinned: Bool = false) -> ClipListItem {
        ClipListItem(id: id, preview: id, clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: isPinned, createdAt: 1, imagePath: nil, attachmentPaths: nil, charCount: 0,
            pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil)
    }

    func testEffectiveTypeFilterBrowseMode() throws {
        let l = try loader()
        XCTAssertNil(l.effectiveTypeFilter(query: "", browseMode: .all))
        XCTAssertEqual(l.effectiveTypeFilter(query: "", browseMode: .text), .text)
        XCTAssertEqual(l.effectiveTypeFilter(query: "", browseMode: .image), .image)
        XCTAssertNil(l.effectiveTypeFilter(query: "", browseMode: .pinned))
    }

    func testEffectiveTypeFilterSearchModeDropsPinned() throws {
        let l = try loader()
        XCTAssertNil(l.effectiveTypeFilter(query: "x", browseMode: .pinned))
        XCTAssertEqual(l.effectiveTypeFilter(query: "x", browseMode: .url), .url)
    }

    func testVisibleSearchReturnsAllRegardlessOfPinned() throws {
        let l = try loader()
        let out = l.visible([item("p", isPinned: true), item("r")], query: "abc", browseMode: .all, excludingID: nil)
        XCTAssertEqual(out.map(\.id), ["p", "r"], "搜索是全局召回,pinned 展示策略不参与过滤")
    }

    func testVisibleExcludesPendingDeletionID() throws {
        let l = try loader()
        let out = l.visible([item("a"), item("b")], query: "x", browseMode: .all, excludingID: "a")
        XCTAssertEqual(out.map(\.id), ["b"])
    }

    func testFetchPagePinnedReturnsOnlyPinned() throws {
        let core = try makeCore()
        _ = try core.importItem(content: "pin", clipType: .text, sourceApp: nil, sourceName: nil,
            imagePath: nil, isPinned: true, createdAt: 2_000, alias: nil)
        _ = try core.importItem(content: "reg", clipType: .text, sourceApp: nil, sourceName: nil,
            imagePath: nil, isPinned: false, createdAt: 1_000, alias: nil)
        let l = BrowsePageLoader(core: core, settings: .shared)
        let page = try l.fetchPage(offset: 0, pageSize: 50, query: "", browseMode: .pinned, excludingID: nil)
        XCTAssertEqual(page.items.map(\.preview), ["pin"])
        XCTAssertFalse(page.hasMore)
    }
}
