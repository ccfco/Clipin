import XCTest
@testable import Clipin

@MainActor
final class AutoBackupServiceTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        super.tearDown()
    }

    /// 启用自动备份且 lastBackupAt 为空时（init 检测 isBackupOverdue() == true），
    /// reconfigure 路径会立即触发 performBackup，无需等定时器。验证：
    /// ① 备份文件能写出来；② 反向 import 验证内容真实。
    func testFreshEnableTriggersImmediateBackup() async throws {
        let previousEnabled = SettingsStore.shared.autoBackupEnabled
        let previousFolder = SettingsStore.shared.autoBackupFolderPath
        let previousInterval = SettingsStore.shared.autoBackupInterval
        SettingsStore.shared.autoBackupEnabled = false
        defer {
            SettingsStore.shared.autoBackupEnabled = previousEnabled
            SettingsStore.shared.autoBackupFolderPath = previousFolder
            SettingsStore.shared.autoBackupInterval = previousInterval
        }

        let (core, rootURL) = try makeCore()
        let backupFolder = rootURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        _ = try core.saveItem(
            content: "saved before init",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )

        // 清掉 UserDefaults 里残留的 lastBackupAt，确保 isBackupOverdue 为 true
        UserDefaults.standard.removeObject(forKey: "autoBackup.lastBackupAt")

        SettingsStore.shared.autoBackupFolderPath = backupFolder.path
        SettingsStore.shared.autoBackupInterval = .hourly
        SettingsStore.shared.autoBackupEnabled = true

        let service = AutoBackupService(core: core, settings: SettingsStore.shared)
        _ = service

        let backupURL = backupFolder.appendingPathComponent(AutoBackupService.backupFilename)
        try await waitUntil { FileManager.default.fileExists(atPath: backupURL.path) }

        let (verifyCore, verifyRoot) = try makeCore()
        _ = verifyRoot
        let result = try await ArchiveService.importArchive(from: backupURL, core: verifyCore)
        XCTAssertGreaterThanOrEqual(result.importedCount, 1)
        let items = try verifyCore.getItems(limit: 50, offset: 0, typeFilter: nil)
        XCTAssertTrue(items.contains { $0.content == "saved before init" })
    }

    func testBackupFilenameContainsHostnameOrDefault() {
        let name = AutoBackupService.backupFilename
        XCTAssertTrue(name.hasSuffix(".clipin.zip"))
        XCTAssertTrue(name.hasPrefix("clipin-backup"))
    }

    /// AutoBackupInterval 三档周期，无 onChange/monthly 残留
    func testAutoBackupIntervalEnumeration() {
        let all = AutoBackupInterval.allCases
        XCTAssertEqual(Set(all.map(\.rawValue)), Set(["hourly", "daily", "weekly"]))
        XCTAssertGreaterThan(AutoBackupInterval.hourly.backupInterval, 0)
        XCTAssertGreaterThan(AutoBackupInterval.daily.backupInterval, AutoBackupInterval.hourly.backupInterval)
        XCTAssertGreaterThan(AutoBackupInterval.weekly.backupInterval, AutoBackupInterval.daily.backupInterval)
    }

    private func makeCore() throws -> (ClipinCore, URL) {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinAutoBackupTests-\(UUID().uuidString)", isDirectory: true)
        let imageURL = rootURL.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageURL, withIntermediateDirectories: true)
        tempRoots.append(rootURL)

        let core = try ClipinCore(
            dbPath: rootURL.appendingPathComponent("test.db").path,
            imageDir: imageURL.path
        )
        return (core, rootURL)
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @escaping () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        while !predicate() {
            if start.duration(to: clock.now) > timeout {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
