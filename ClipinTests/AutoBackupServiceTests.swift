import XCTest
@testable import Clipin

@MainActor
final class AutoBackupServiceTests: XCTestCase {
    private var tempRoots: [URL] = []

    /// 关键：测试用 SettingsStore.shared + UserDefaults.standard，AutoBackupService
    /// 的 applySuccess 会把 lastBackupAt/URL/Size/Skipped 写进 UserDefaults。
    /// defer 只恢复 settings 不恢复 UserDefaults backup state——会让用户真实 app
    /// 启动时看到测试 tmp 路径的"假上次备份"。每个测试结束必须清掉所有 autoBackup.*
    /// keys，避免污染本机 production 状态。
    private static let autoBackupDefaultsKeys = [
        "autoBackup.lastBackupAt",
        "autoBackup.lastBackupSize",
        "autoBackup.lastBackupURL",
        "autoBackup.lastBackupSkipped",
        "autoBackup.consecutiveFailures",
        "autoBackup.paused",
    ]

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        for key in Self.autoBackupDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
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

        // 诊断: CI flaky 排查——dump 备份文件状态 / source core 的可见 item 数。
        // 本地 PASS 但 CI FAIL 时,这块日志告诉我们 root cause 在哪一层
        // (① source core 没数据 ② 备份归档构造时丢失 ③ import 路径解析失败)。
        // 修复后可删除。
        let sourceItems = (try? core.getItems(limit: 50, offset: 0, typeFilter: nil)) ?? []
        let exportSnapshot = (try? core.exportArchiveSnapshot()) ?? []
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: backupURL.path))
            .flatMap { $0[.size] as? Int64 } ?? -1

        // 把 zip 解开看 manifest.json 实际内容(不是只看大小)——
        // 357 bytes vs 449 bytes 差异显示归档结构本身不同,manifest 才是真相。
        var manifestJSON: String = "<unzip failed>"
        let inspectDir = FileManager.default.temporaryDirectory.appendingPathComponent("DIAG-inspect-\(UUID().uuidString)")
        if let _ = try? FileManager.default.createDirectory(at: inspectDir, withIntermediateDirectories: true) {
            let process = Process()
            process.launchPath = "/usr/bin/unzip"
            process.arguments = ["-o", backupURL.path, "-d", inspectDir.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let manifestPath = inspectDir.appendingPathComponent("manifest.json").path
            if let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
               let txt = String(data: data, encoding: .utf8) {
                manifestJSON = String(txt.prefix(1000))
            }
            try? FileManager.default.removeItem(at: inspectDir)
        }

        print("[AutoBackupTest:DIAG] backupURL=\(backupURL.path)")
        print("[AutoBackupTest:DIAG] backupFile size=\(fileSize) bytes")
        // 列出 backupFolder 内所有文件,捕获 ".previous" 或 ".tmp" 残留情况
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: backupFolder.path)) ?? []
        for f in allFiles {
            let path = backupFolder.appendingPathComponent(f).path
            let s = (try? FileManager.default.attributesOfItem(atPath: path)).flatMap { $0[.size] as? Int64 } ?? -1
            print("[AutoBackupTest:DIAG] folder[\(f)] size=\(s)")
        }
        print("[AutoBackupTest:DIAG] sourceCore items count=\(sourceItems.count)")
        print("[AutoBackupTest:DIAG] sourceCore contents=\(sourceItems.prefix(5).map { String($0.content.prefix(40)) })")
        print("[AutoBackupTest:DIAG] exportArchiveSnapshot count=\(exportSnapshot.count)")
        print("[AutoBackupTest:DIAG] manifest.json=\(manifestJSON)")
        print("[AutoBackupTest:DIAG] backupFilename=\(AutoBackupService.backupFilename)")
        print("[AutoBackupTest:DIAG] settings.folderPath=\(SettingsStore.shared.autoBackupFolderPath ?? "nil")")

        let (verifyCore, verifyRoot) = try makeCore()
        _ = verifyRoot
        let result = try await ArchiveService.importArchive(from: backupURL, core: verifyCore)
        print("[AutoBackupTest:DIAG] importResult imported=\(result.importedCount) skippedDup=\(result.skippedDuplicateCount) skippedMissingImg=\(result.skippedMissingImageCount) failedRep=\(result.failedRepresentationCount)")
        XCTAssertGreaterThanOrEqual(result.importedCount, 1)
        let items = try verifyCore.getItems(limit: 50, offset: 0, typeFilter: nil)
        print("[AutoBackupTest:DIAG] verifyCore items count=\(items.count) contents=\(items.prefix(5).map { String($0.content.prefix(40)) })")
        XCTAssertTrue(items.contains { $0.content == "saved before init" })
    }

    /// 修 B2 防回归：lastBackupURL 指向不在当前 settings.autoBackupFolderPath 下的
    /// 路径时（典型场景：测试残留的 tmp 路径污染了 UserDefaults），init 必须自愈
    /// 清掉所有 lastBackup* 状态，否则设置页永久显示"假上次备份"。
    func testInitPurgesStaleBackupStateWhenURLOutsideCurrentFolder() throws {
        let previousFolder = SettingsStore.shared.autoBackupFolderPath
        defer { SettingsStore.shared.autoBackupFolderPath = previousFolder }

        let (core, rootURL) = try makeCore()
        let realFolder = rootURL.appendingPathComponent("real-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        SettingsStore.shared.autoBackupFolderPath = realFolder.path

        // 注入「测试残留」状态：UserDefaults 里指向另一个 tmp 路径的旧备份记录
        let stalePath = "/private/var/folders/stale/old-test-backup.clipin.zip"
        let d = UserDefaults.standard
        d.set(Date(), forKey: "autoBackup.lastBackupAt")
        d.set(stalePath, forKey: "autoBackup.lastBackupURL")
        d.set(NSNumber(value: Int64(12345)), forKey: "autoBackup.lastBackupSize")
        d.set(7, forKey: "autoBackup.lastBackupSkipped")

        let service = AutoBackupService(core: core, settings: SettingsStore.shared)

        XCTAssertNil(service.lastBackupAt, "stale lastBackupAt must be purged")
        XCTAssertNil(service.lastBackupURL, "stale lastBackupURL must be purged")
        XCTAssertEqual(service.lastBackupSize, 0)
        XCTAssertEqual(service.lastBackupSkipped, 0)
        // 持久化也要清掉
        XCTAssertNil(d.object(forKey: "autoBackup.lastBackupAt"))
        XCTAssertNil(d.string(forKey: "autoBackup.lastBackupURL"))
    }

    /// 对偶测试：lastBackupURL 就在当前 folder 下 → 保留状态不清掉
    func testInitKeepsBackupStateWhenURLInsideCurrentFolder() throws {
        let previousFolder = SettingsStore.shared.autoBackupFolderPath
        defer { SettingsStore.shared.autoBackupFolderPath = previousFolder }

        let (core, rootURL) = try makeCore()
        let realFolder = rootURL.appendingPathComponent("real-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        SettingsStore.shared.autoBackupFolderPath = realFolder.path

        let validURL = realFolder.appendingPathComponent("clipin-backup-Host.clipin.zip")
        let date = Date()
        let d = UserDefaults.standard
        d.set(date, forKey: "autoBackup.lastBackupAt")
        d.set(validURL.path, forKey: "autoBackup.lastBackupURL")
        d.set(NSNumber(value: Int64(99999)), forKey: "autoBackup.lastBackupSize")

        let service = AutoBackupService(core: core, settings: SettingsStore.shared)

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

        UserDefaults.standard.removeObject(forKey: "autoBackup.lastBackupAt")
        UserDefaults.standard.removeObject(forKey: "autoBackup.lastBackupSkipped")
        SettingsStore.shared.autoBackupFolderPath = backupFolder.path
        SettingsStore.shared.autoBackupInterval = .hourly
        SettingsStore.shared.autoBackupEnabled = true

        let service = AutoBackupService(core: core, settings: SettingsStore.shared)

        try await waitUntil {
            service.lastBackupAt != nil && !service.isBackingUp
        }
        XCTAssertGreaterThan(
            service.lastBackupSkipped, 0,
            "partial backup must surface skippedCount to Published state, otherwise UI shows green success"
        )
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
