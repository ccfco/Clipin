import XCTest
@testable import Clipin

final class BackupCleanupServiceTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    func testScanIdentifiesLegacyAndForeignBackupsOnly() throws {
        let folder = try makeBackupFolder()
        let host = "MyMac"

        // 应该被识别为候选：
        try writeFile(folder, "clipin-backup.json", size: 100)                   // v1/v2 老 JSON
        try writeFile(folder, "clipin-backup.previous.json", size: 200)          // v1/v2 旁路
        try writeFile(folder, "clipin-backup-OtherMac.clipin.zip", size: 300)    // 其他设备
        try writeFile(folder, "clipin-backup-OtherMac.previous.clipin.zip", size: 400) // 其他设备旁路

        // 不应该被识别（保留）：
        try writeFile(folder, "clipin-backup-MyMac.clipin.zip", size: 500)       // 本机主备份
        try writeFile(folder, "clipin-backup-MyMac.previous.clipin.zip", size: 600) // 本机安全网
        try writeFile(folder, "clipin-backup.clipin.zip", size: 700)             // 无 hostname（保留）
        try writeFile(folder, "Clipin-2026-05-25-1430.clipin.zip", size: 800)    // 手动导出
        try writeFile(folder, "random-user-file.zip", size: 900)                 // 用户自己的文件

        let candidates = BackupCleanupService.scan(folderURL: folder, currentHostSlug: host)
        let names = Set(candidates.map(\.displayName))

        XCTAssertEqual(names, Set([
            "clipin-backup.json",
            "clipin-backup.previous.json",
            "clipin-backup-OtherMac.clipin.zip",
            "clipin-backup-OtherMac.previous.clipin.zip",
        ]))
    }

    func testDeleteOnlyRemovesGivenCandidates() throws {
        let folder = try makeBackupFolder()
        try writeFile(folder, "clipin-backup.json", size: 50)
        try writeFile(folder, "clipin-backup-MyMac.clipin.zip", size: 100)

        let candidates = BackupCleanupService.scan(folderURL: folder, currentHostSlug: "MyMac")
        XCTAssertEqual(candidates.count, 1)

        let deleted = BackupCleanupService.delete(candidates)
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clipin-backup.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clipin-backup-MyMac.clipin.zip").path))
    }

    func testScanReturnsEmptyForMissingFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(BackupCleanupService.scan(folderURL: missing, currentHostSlug: "MyMac").isEmpty)
    }

    // MARK: - Helpers

    private func makeBackupFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinBackupCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func writeFile(_ folder: URL, _ name: String, size: Int) throws {
        let url = folder.appendingPathComponent(name)
        let data = Data(repeating: 0xAB, count: size)
        try data.write(to: url)
    }
}
