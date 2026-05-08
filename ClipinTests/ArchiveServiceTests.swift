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
