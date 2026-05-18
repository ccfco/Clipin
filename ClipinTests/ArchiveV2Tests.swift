import XCTest
@testable import Clipin

final class ArchiveV2Tests: XCTestCase {
    func testV2RoundtripPreservesRepresentations() async throws {
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

        let archiveURL = tmpDir.appendingPathComponent("archive.json")
        _ = try await ArchiveService.writeArchive(to: archiveURL, core: core)

        let tmpDir2 = try makeTmpDir()
        let core2 = try ClipinCore(dbPath: tmpDir2.appendingPathComponent("db").path,
                                   imageDir: tmpDir2.appendingPathComponent("images").path)
        _ = try await ArchiveService.importArchive(from: archiveURL, core: core2)

        let items = core2.getItems(limit: 10, offset: 0, typeFilter: nil)
        XCTAssertEqual(items.count, 1)
        let loaded = try core2.getRepresentations(id: items[0].id)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first(where: { $0.uti == "public.html" })?.data, Data("<p>hi</p>".utf8))
    }

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

        let items = core.getItems(limit: 10, offset: 0, typeFilter: nil)
        let reps = try core.getRepresentations(id: items[0].id)
        XCTAssertEqual(reps.count, 0)
    }

    private func makeTmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
