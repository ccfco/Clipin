import XCTest
@testable import Clipin

/// 历史命名沿用 V2：当时 archive schema v2 引入 representations。
/// 现在 ArchiveService 写出固定为 v3 zip 格式，但兼容 v1/v2 单 JSON 导入。
/// 测试同时覆盖 v3 round-trip 与 v1/v2 向后兼容导入。
final class ArchiveV2Tests: XCTestCase {

    // MARK: - v3 round-trip

    func testV3RoundtripPreservesRepresentations() async throws {
        let tmpDir = try makeTmpDir()
        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: tmpDir.appendingPathComponent("images").path)

        let reps = [
            ClipRepresentation(uti: "public.html", data: Data("<p>hi</p>".utf8)),
            ClipRepresentation(uti: "public.rtf",  data: Data("{\\rtf1 hi}".utf8)),
        ]
        _ = try core.saveItemWithRepresentations(
            content: "hi", clipType: .text,
            sourceApp: nil, sourceName: nil, imagePath: nil,
            representations: reps
        )

        // v3 后缀 .clipin.zip：writeArchive 一律按 v3 zip 写出
        let archiveURL = tmpDir.appendingPathComponent("archive.clipin.zip")
        let exportResult = try await ArchiveService.writeArchive(to: archiveURL, core: core)
        XCTAssertEqual(exportResult.exportedCount, 1)
        XCTAssertGreaterThan(exportResult.archiveSize, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))

        let tmpDir2 = try makeTmpDir()
        let core2 = try ClipinCore(dbPath: tmpDir2.appendingPathComponent("db").path,
                                   imageDir: tmpDir2.appendingPathComponent("images").path)
        _ = try await ArchiveService.importArchive(from: archiveURL, core: core2)

        let items = try core2.getItems(limit: 10, offset: 0, typeFilter: nil)
        XCTAssertEqual(items.count, 1)
        let loaded = try core2.getRepresentations(id: items[0].id)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first(where: { $0.uti == "public.html" })?.data, Data("<p>hi</p>".utf8))
    }

    func testV3RoundtripPreservesImageBytes() async throws {
        let tmpDir = try makeTmpDir()
        let imagesDir = tmpDir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: imagesDir.path)

        // 写一张"图片"（任意字节即可，archive 是按字节内容做 SHA256 寻址）
        let originalBytes = Data((0..<2048).map { UInt8($0 & 0xff) })
        let originalImageURL = imagesDir.appendingPathComponent("orig.png")
        try originalBytes.write(to: originalImageURL)

        _ = try core.saveItem(
            content: "image",
            clipType: .image,
            sourceApp: nil,
            sourceName: nil,
            imagePath: originalImageURL.path
        )

        let archiveURL = tmpDir.appendingPathComponent("img.clipin.zip")
        _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)

        // 导入到新库，验证图片字节一致
        let tmpDir2 = try makeTmpDir()
        let imagesDir2 = tmpDir2.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir2, withIntermediateDirectories: true)
        let core2 = try ClipinCore(dbPath: tmpDir2.appendingPathComponent("db").path,
                                   imageDir: imagesDir2.path)
        let result = try await ArchiveService.importArchive(from: archiveURL, core: core2)
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedMissingImageCount, 0)

        let items = try core2.getItems(limit: 10, offset: 0, typeFilter: .image)
        XCTAssertEqual(items.count, 1)
        let importedPath = try XCTUnwrap(items[0].imagePath)
        let importedBytes = try Data(contentsOf: URL(fileURLWithPath: importedPath))
        XCTAssertEqual(importedBytes, originalBytes)
    }

    func testPreviousArchiveURLDerivation() {
        let base = URL(fileURLWithPath: "/tmp/foo/clipin-backup.clipin.zip")
        XCTAssertEqual(
            ArchiveService.previousArchiveURL(for: base).lastPathComponent,
            "clipin-backup.previous.clipin.zip"
        )
        XCTAssertEqual(
            ArchiveService.previousArchiveURL(for: URL(fileURLWithPath: "/x/y.zip")).lastPathComponent,
            "y.previous.zip"
        )
        XCTAssertEqual(
            ArchiveService.previousArchiveURL(for: URL(fileURLWithPath: "/x/y.json")).lastPathComponent,
            "y.previous.json"
        )
    }

    func testWritingArchiveRotatesPreviousFile() async throws {
        let tmpDir = try makeTmpDir()
        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: tmpDir.appendingPathComponent("images").path)
        _ = try core.saveItem(content: "first", clipType: .text,
                              sourceApp: nil, sourceName: nil, imagePath: nil)

        let archiveURL = tmpDir.appendingPathComponent("rotate.clipin.zip")
        let previousURL = ArchiveService.previousArchiveURL(for: archiveURL)

        // 第一次写：previous 不应该存在
        _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousURL.path))

        // 增加一条再写：旧的 archive 应该被 rename 为 previous
        _ = try core.saveItem(content: "second", clipType: .text,
                              sourceApp: nil, sourceName: nil, imagePath: nil)
        _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousURL.path))
    }

    // MARK: - 旧格式向后兼容

    func testV1ArchiveImportsAsBackwardCompatible() async throws {
        let tmpDir = try makeTmpDir()
        let v1JSON = """
        {
          "schemaVersion": 1,
          "exportedAt": "2025-01-01T00:00:00Z",
          "items": [{
            "content": "hi",
            "clipType": "text",
            "sourceApp": null,
            "sourceName": null,
            "isPinned": false,
            "createdAt": 1715000000,
            "imageDataBase64": null
          }]
        }
        """
        let url = tmpDir.appendingPathComponent("v1.json")
        try v1JSON.data(using: .utf8)!.write(to: url)

        let core = try ClipinCore(dbPath: tmpDir.appendingPathComponent("db").path,
                                  imageDir: tmpDir.appendingPathComponent("images").path)
        let result = try await ArchiveService.importArchive(from: url, core: core)
        XCTAssertEqual(result.importedCount, 1)

        let items = try core.getItems(limit: 10, offset: 0, typeFilter: nil)
        let reps = try core.getRepresentations(id: items[0].id)
        XCTAssertEqual(reps.count, 0)
    }

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
