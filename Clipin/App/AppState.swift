import AppKit
import SwiftUI

/// 全局应用状态
/// ClipinCore 内部用 Mutex 保证线程安全，不需要 @MainActor
final class AppState: ObservableObject, @unchecked Sendable {
    static let shared = AppState()

    let core: ClipinCore
    /// 在当前进程首次创建目录/数据库之前，本地存储是否已经存在。
    /// 用于区分“全新安装”和“已有安装升级”，避免老用户被重新拉进 onboarding。
    let hadExistingStorageBeforeBootstrap: Bool

    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clipinDir = appSupport.appendingPathComponent("Clipin")
        let dbPath = clipinDir.appendingPathComponent("clipin.db").path
        let imageDir = clipinDir.appendingPathComponent("images").path
        self.hadExistingStorageBeforeBootstrap =
            fileManager.fileExists(atPath: clipinDir.path) ||
            fileManager.fileExists(atPath: dbPath) ||
            fileManager.fileExists(atPath: imageDir)

        try? fileManager.createDirectory(atPath: clipinDir.path, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: imageDir, withIntermediateDirectories: true)

        do {
            self.core = try ClipinCore(dbPath: dbPath, imageDir: imageDir)
            print("✅ ClipinCore initialized: \(dbPath)")
        } catch {
            fatalError("❌ Failed to initialize ClipinCore: \(error)")
        }
    }
}
