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

    func testOnChangeBackupRunsAfterClipboardItemSavedNotification() async throws {
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

        SettingsStore.shared.autoBackupFolderPath = backupFolder.path
        SettingsStore.shared.autoBackupInterval = .onChange
        SettingsStore.shared.autoBackupEnabled = true

        // minimumInterval 设为 0 让测试不走 5 分钟节流（lastBackupAt nil 时本来就跳过节流，
        // 但 changeDebounceDelay 之后的逻辑保险起见显式置 0）
        let service = AutoBackupService(
            core: core,
            settings: SettingsStore.shared,
            changeDebounceDelay: .milliseconds(50),
            minimumInterval: 0
        )
        _ = service

        _ = try core.saveItem(
            content: "saved after observer",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )
        NotificationCenter.default.post(name: .clipHistoryItemSaved, object: nil)

        let backupURL = backupFolder.appendingPathComponent(AutoBackupService.backupFilename)
        // v3 zip：文件存在且能反向导入回新 core，且条目内容匹配
        try await waitUntil {
            FileManager.default.fileExists(atPath: backupURL.path)
        }

        // 反向 import 验证内容（用一个全新 core 避免被现存 dedup 干扰）
        let (verifyCore, verifyRoot) = try makeCore()
        _ = verifyRoot
        let result = try await ArchiveService.importArchive(from: backupURL, core: verifyCore)
        XCTAssertGreaterThanOrEqual(result.importedCount, 1)
        let items = try verifyCore.getItems(limit: 50, offset: 0, typeFilter: nil)
        XCTAssertTrue(items.contains { $0.content == "saved after observer" })
    }

    func testBackupFilenameContainsHostnameOrDefault() {
        let name = AutoBackupService.backupFilename
        XCTAssertTrue(name.hasSuffix(".clipin.zip"))
        XCTAssertTrue(name.hasPrefix("clipin-backup"))
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
