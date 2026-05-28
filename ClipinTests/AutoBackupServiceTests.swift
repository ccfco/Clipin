import XCTest
@testable import Clipin

@MainActor
final class AutoBackupServiceTests: XCTestCase {
    private var tempRoots: [URL] = []
    /// 每个测试用独立 UserDefaults suite，跑完整体 removePersistentDomain。
    /// 关键隔离：测试不再碰 SettingsStore.shared / UserDefaults.standard——否则在
    /// app-hosted 测试进程里改全局备份设置会唤醒 production 的 AutoBackupService.shared
    /// sink，它用空的 production core 抢写同一个备份文件，造成 CI flaky（357B 空 manifest
    /// 覆盖 449B 真数据）。独立 suite + 注入式 SettingsStore/AutoBackupService 彻底断开。
    private var suiteNames: [String] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    /// 启用自动备份且 lastBackupAt 为空时（init 检测 isBackupOverdue() == true），
    /// reconfigure 路径会立即触发 performBackup，无需等定时器。验证：
    /// ① 备份文件能写出来；② 反向 import 验证内容真实。
    func testFreshEnableTriggersImmediateBackup() async throws {
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

        // 独立 suite 天然没有 lastBackupAt → isBackupOverdue 为 true
        let (settings, defaults) = makeSettings()
        settings.autoBackupFolderPath = backupFolder.path
        settings.autoBackupInterval = .hourly
        settings.autoBackupEnabled = true

        let service = AutoBackupService(core: core, settings: settings, defaults: defaults)
        _ = service

        let backupURL = backupFolder.appendingPathComponent(AutoBackupService.backupFilename)
        try await waitUntil { FileManager.default.fileExists(atPath: backupURL.path) }

        // 反向 import 验证备份内容真实（不只是文件存在）——确认归档里真有那条 item。
        let (verifyCore, verifyRoot) = try makeCore()
        _ = verifyRoot
        let result = try await ArchiveService.importArchive(from: backupURL, core: verifyCore)
        XCTAssertGreaterThanOrEqual(result.importedCount, 1)
        let items = try verifyCore.getItems(limit: 50, offset: 0, typeFilter: nil)
        XCTAssertTrue(items.contains { $0.content == "saved before init" })
    }

    /// 修 B2 防回归：lastBackupURL 指向不在当前 settings.autoBackupFolderPath 下的
    /// 路径时（典型场景：旧备份记录残留），init 必须自愈清掉所有 lastBackup* 状态，
    /// 否则设置页永久显示"假上次备份"。
    func testInitPurgesStaleBackupStateWhenURLOutsideCurrentFolder() throws {
        let (core, rootURL) = try makeCore()
        let realFolder = rootURL.appendingPathComponent("real-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let (settings, defaults) = makeSettings()
        settings.autoBackupFolderPath = realFolder.path

        // 注入「残留」状态：suite 里指向另一个 tmp 路径的旧备份记录
        let stalePath = "/private/var/folders/stale/old-test-backup.clipin.zip"
        defaults.set(Date(), forKey: "autoBackup.lastBackupAt")
        defaults.set(stalePath, forKey: "autoBackup.lastBackupURL")
        defaults.set(NSNumber(value: Int64(12345)), forKey: "autoBackup.lastBackupSize")
        defaults.set(7, forKey: "autoBackup.lastBackupSkipped")

        let service = AutoBackupService(core: core, settings: settings, defaults: defaults)

        XCTAssertNil(service.lastBackupAt, "stale lastBackupAt must be purged")
        XCTAssertNil(service.lastBackupURL, "stale lastBackupURL must be purged")
        XCTAssertEqual(service.lastBackupSize, 0)
        XCTAssertEqual(service.lastBackupSkipped, 0)
        // 持久化也要清掉
        XCTAssertNil(defaults.object(forKey: "autoBackup.lastBackupAt"))
        XCTAssertNil(defaults.string(forKey: "autoBackup.lastBackupURL"))
    }

    /// 对偶测试：lastBackupURL 就在当前 folder 下 → 保留状态不清掉
    func testInitKeepsBackupStateWhenURLInsideCurrentFolder() throws {
        let (core, rootURL) = try makeCore()
        let realFolder = rootURL.appendingPathComponent("real-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let (settings, defaults) = makeSettings()
        settings.autoBackupFolderPath = realFolder.path

        let validURL = realFolder.appendingPathComponent("clipin-backup-Host.clipin.zip")
        let date = Date()
        defaults.set(date, forKey: "autoBackup.lastBackupAt")
        defaults.set(validURL.path, forKey: "autoBackup.lastBackupURL")
        defaults.set(NSNumber(value: Int64(99999)), forKey: "autoBackup.lastBackupSize")

        let service = AutoBackupService(core: core, settings: settings, defaults: defaults)

        XCTAssertEqual(service.lastBackupAt, date)
        XCTAssertEqual(service.lastBackupURL, validURL)
        XCTAssertEqual(service.lastBackupSize, 99999)
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

    /// 修 A 防回归：image 文件丢失 → ArchiveService.skippedCount > 0 →
    /// AutoBackupService.lastBackupSkipped 必须同步暴露给 UI（partial backup 不能
    /// 沉默成功），否则用户依赖此备份恢复时会少数据。
    func testPartialBackupExposesSkippedCountToService() async throws {
        let (core, rootURL) = try makeCore()
        let backupFolder = rootURL.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)

        // 写一张图，让 DB 知道有 image 条目；再把图文件物理删掉模拟"image 文件丢失"。
        // archive 写盘时 imageData 读不到 → skippedCount += 1 continue。
        let imagesDir = rootURL.appendingPathComponent("images", isDirectory: true)
        let imageFile = imagesDir.appendingPathComponent("ghost.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageFile)
        _ = try core.saveItem(
            content: "ghost-image",
            clipType: .image,
            sourceApp: nil,
            sourceName: nil,
            imagePath: imageFile.path
        )
        // 删掉图文件让 ArchiveService 读不到
        try FileManager.default.removeItem(at: imageFile)
        // 再加一条文本，保证 archive 至少有内容写出来（避免 0 item 的退化测试）
        _ = try core.saveItem(
            content: "text-keeper",
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            imagePath: nil
        )

        let (settings, defaults) = makeSettings()
        settings.autoBackupFolderPath = backupFolder.path
        settings.autoBackupInterval = .hourly
        settings.autoBackupEnabled = true

        let service = AutoBackupService(core: core, settings: settings, defaults: defaults)

        try await waitUntil {
            service.lastBackupAt != nil && !service.isBackingUp
        }
        XCTAssertGreaterThan(
            service.lastBackupSkipped, 0,
            "partial backup must surface skippedCount to Published state, otherwise UI shows green success"
        )
    }

    // MARK: - Helpers

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

    /// 独立 SettingsStore + 独立 UserDefaults suite，与 production .shared/.standard 完全隔离。
    private func makeSettings() -> (SettingsStore, UserDefaults) {
        let suiteName = "ClipinAutoBackupTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("failed to create isolated UserDefaults suite")
        }
        suiteNames.append(suiteName)
        let settings = SettingsStore(defaults: defaults)
        return (settings, defaults)
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
