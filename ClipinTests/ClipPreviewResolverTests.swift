import XCTest
@testable import Clipin

final class ClipPreviewResolverTests: XCTestCase {
    func testResolveSessionCanLimitDetailLoadsAroundSelection() {
        let items = (0..<101).map { index in
            ClipListItem(
                id: "url-\(index)",
                preview: "https://example.com/\(index)",
                clipType: .url,
                sourceApp: nil,
                sourceName: nil,
                isPinned: false,
                createdAt: Int64(index),
                imagePath: nil,
                charCount: 0,
                pasteCount: 0,
                copyCount: 1
            )
        }
        var loadedIDs: [String] = []

        let session = ClipPreviewResolver.resolveSession(
            items: items,
            selectedItemID: "url-50",
            neighborItemLimit: 3
        ) { id in
            loadedIDs.append(id)
            return ClipItem(
                id: id,
                content: "https://example.com/\(id)",
                clipType: .url,
                sourceApp: nil,
                sourceName: nil,
                isPinned: false,
                createdAt: 0,
                imagePath: nil,
                charCount: 0,
                copyCount: 1,
                firstCopiedAt: 0,
                ocrText: nil,
                pasteCount: 0
            )
        }

        XCTAssertEqual(loadedIDs, (47...53).map { "url-\($0)" })
        XCTAssertEqual(session?.selectedIndex, 3)
        XCTAssertEqual(session?.entries.count, 7)
    }
}
