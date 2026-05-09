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

        let service = AutoBackupService(
            core: core,
            settings: SettingsStore.shared,
            changeDebounceDelay: .milliseconds(50)
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
        try await waitUntil {
            guard let data = try? Data(contentsOf: backupURL),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("saved after observer")
        }
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
        timeout: Duration = .seconds(2),
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
