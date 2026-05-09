import XCTest
@testable import Clipin

final class ArchiveServiceTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    func testWriteArchiveHonorsCancellationBeforeStarting() async throws {
        let (core, rootURL) = try makeCore()
        _ = try core.saveItem(
            content: "cancel me",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        let archiveURL = rootURL.appendingPathComponent("cancelled-backup.json")

        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)
        }

        do {
            try await task.value
            XCTFail("Expected writeArchive to throw CancellationError")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
        }
    }

    func testImportArchiveSkipsDuplicateItemsAndPreservesExistingUsage() async throws {
        let (core, rootURL) = try makeCore()
        let existing = try core.saveItem(
            content: "same item",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        try core.incrementPasteCount(id: existing.id)

        let archiveURL = rootURL.appendingPathComponent("duplicate.json")
        let archiveJSON = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-09T00:00:00Z",
          "items": [
            {
              "content": "same item",
              "clipType": "text",
              "sourceApp": "com.example.old",
              "sourceName": "Old App",
              "isPinned": true,
              "createdAt": 1000,
              "imageDataBase64": null
            }
          ]
        }
        """
        try archiveJSON.data(using: .utf8)!.write(to: archiveURL)

        let result = try await ArchiveService.importArchive(from: archiveURL, core: core)
        let items = core.getItems(limit: 10, offset: 0, typeFilter: nil)

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.skippedDuplicateCount, 1)
        XCTAssertEqual(result.skippedMissingImageCount, 0)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, existing.id)
        XCTAssertEqual(items[0].pasteCount, 1)
        XCTAssertFalse(items[0].isPinned)
    }

    func testImportArchiveRepairsDuplicateImageWhenExistingFileIsMissing() async throws {
        let (core, rootURL) = try makeCore()
        let oldImageURL = rootURL.appendingPathComponent("old-image.png")
        let imageData = Data("repair-image".utf8)
        try imageData.write(to: oldImageURL)
        let existing = try core.importItem(
            content: "image",
            clipType: .image,
            sourceApp: nil,
            sourceName: nil,
            imagePath: oldImageURL.path,
            isPinned: false,
            createdAt: 1_000
        )
        try core.incrementPasteCount(id: existing.id)
        try FileManager.default.removeItem(at: oldImageURL)

        let archiveURL = rootURL.appendingPathComponent("repair-image.json")
        let archiveJSON = """
        {
          "schemaVersion": 1,
          "exportedAt": "2026-05-09T00:00:00Z",
          "items": [
            {
              "content": "image",
              "clipType": "image",
              "sourceApp": "com.example.old",
              "sourceName": "Old App",
              "isPinned": true,
              "createdAt": 2000,
              "imageDataBase64": "\(imageData.base64EncodedString())"
            }
          ]
        }
        """
        try archiveJSON.data(using: .utf8)!.write(to: archiveURL)

        let result = try await ArchiveService.importArchive(from: archiveURL, core: core)
        let items = core.getItems(limit: 10, offset: 0, typeFilter: .image)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedDuplicateCount, 0)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, existing.id)
        XCTAssertEqual(items[0].pasteCount, 1)
        XCTAssertFalse(items[0].isPinned)
        let repairedPath = try XCTUnwrap(items[0].imagePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repairedPath))
        XCTAssertNotEqual(repairedPath, oldImageURL.path)
    }

    private func makeCore() throws -> (ClipinCore, URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)

        let core = try ClipinCore(
            dbPath: rootURL.appendingPathComponent("test.db").path,
            imageDir: imageURL.path
        )
        return (core, rootURL)
    }
}
