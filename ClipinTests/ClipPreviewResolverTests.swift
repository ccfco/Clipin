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
                attachmentPaths: nil,
                charCount: 0,
                pasteCount: 0,
                copyCount: 1,
                imageWidth: nil,
                imageHeight: nil,
                alias: nil
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
                attachmentPaths: nil,
                charCount: 0,
                copyCount: 1,
                firstCopiedAt: 0,
                ocrText: nil,
                pasteCount: 0,
                alias: nil,
                aiTags: nil
            )
        }

        XCTAssertEqual(loadedIDs, (47...53).map { "url-\($0)" })
        XCTAssertEqual(session?.selectedIndex, 3)
        XCTAssertEqual(session?.entries.count, 7)
    }

    func testResolveTextFolderPathWithCacheAndDiskProbe() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipPreviewResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let folderPath = rootURL.path
        let folderItem = ClipItem(
            id: "text-folder",
            content: folderPath,
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            attachmentPaths: nil,
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0,
            alias: nil,
            aiTags: nil
        )

        // With allowDiskProbe: true, resolves directly
        let probed = ClipPreviewResolver.resolve(item: folderItem, allowDiskProbe: true)
        XCTAssertEqual(probed?.count, 1)
        XCTAssertEqual(probed?.first?.url.standardizedFileURL.path, rootURL.standardizedFileURL.path)

        // Warming PreviewMetadataCache enables sync resolve(allowDiskProbe: false)
        _ = await PreviewMetadataCache.shared.loadLocalPath(for: folderPath)
        let cached = ClipPreviewResolver.resolve(item: folderItem, allowDiskProbe: false)
        XCTAssertEqual(cached?.count, 1)

        // Missing path or multiline text never resolves
        let missingItem = ClipItem(
            id: "text-missing",
            content: folderPath + "/definitely-does-not-exist",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            attachmentPaths: nil,
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0,
            alias: nil,
            aiTags: nil
        )
        XCTAssertNil(ClipPreviewResolver.resolve(item: missingItem, allowDiskProbe: true))

        let multilineItem = ClipItem(
            id: "text-multiline",
            content: "\(folderPath)\n\(folderPath)",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            attachmentPaths: nil,
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0,
            alias: nil,
            aiTags: nil
        )
        XCTAssertNil(ClipPreviewResolver.resolve(item: multilineItem, allowDiskProbe: true))
    }
}
