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

        let candidates = try BackupCleanupService.scan(folderURL: folder, currentHostSlug: host)
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

        let candidates = try BackupCleanupService.scan(folderURL: folder, currentHostSlug: "MyMac")
        XCTAssertEqual(candidates.count, 1)

        let deleted = BackupCleanupService.delete(candidates)
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clipin-backup.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clipin-backup-MyMac.clipin.zip").path))
    }

    /// 修 C 后：缺失文件夹 → throws ScanError.folderMissing 而不是返回空数组——
    /// 调用方（SettingsView）凭这个错误区分"真的没遗留"和"扫描失败"，不沉默吞掉。
    func testScanThrowsForMissingFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(
            try BackupCleanupService.scan(folderURL: missing, currentHostSlug: "MyMac")
        ) { error in
            guard case BackupCleanupService.ScanError.folderMissing = error else {
                XCTFail("expected folderMissing, got \(error)"); return
            }
        }
    }

    /// 用户在 System Settings 改了电脑名大小写后，旧本机备份文件名仍是旧大小写——
    /// classify 必须按 case-insensitive 比较，避免把旧本机备份误判为 foreign。
    func testHostnameCaseDifferenceIsNotForeign() throws {
        let folder = try makeBackupFolder()
        try writeFile(folder, "clipin-backup-MyMac.clipin.zip", size: 100)
        try writeFile(folder, "clipin-backup-MyMac.previous.clipin.zip", size: 200)

        let candidates = try BackupCleanupService.scan(folderURL: folder, currentHostSlug: "mymac")
        XCTAssertEqual(candidates.count, 0, "case-only difference must not classify as foreign")
    }

    /// 空 hostname slug（机器名全是空格/标点被过滤光了）时，本机备份文件名是
    /// `clipin-backup.clipin.zip`（无 hostname 后缀）。这条根本不进 hostname 匹配
    /// 分支，不归类——保护逻辑由 stem.isEmpty 兜底。
    func testEmptyCurrentHostSlugDoesNotMisclassifyBareBackup() throws {
        let folder = try makeBackupFolder()
        try writeFile(folder, "clipin-backup.clipin.zip", size: 100)
        try writeFile(folder, "clipin-backup-someslug.clipin.zip", size: 200)

        let candidates = try BackupCleanupService.scan(folderURL: folder, currentHostSlug: "")
        // 无 hostname 文件保留；someslug 在空 currentHost 下任何 slug 都是 foreign
        XCTAssertEqual(Set(candidates.map(\.displayName)), Set(["clipin-backup-someslug.clipin.zip"]))
    }

    /// Unicode hostname（中文等）：sanitizedHostname 保留 Unicode alphanumerics，
    /// 验证比较仍然 case-insensitive 工作。
    func testUnicodeHostnameClassification() throws {
        let folder = try makeBackupFolder()
        try writeFile(folder, "clipin-backup-陈雷的MacBook.clipin.zip", size: 100)
        try writeFile(folder, "clipin-backup-OtherMac.clipin.zip", size: 200)

        let candidates = try BackupCleanupService.scan(folderURL: folder, currentHostSlug: "陈雷的MacBook")
        XCTAssertEqual(Set(candidates.map(\.displayName)), Set(["clipin-backup-OtherMac.clipin.zip"]))
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
