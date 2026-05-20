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

        // 目录创建失败 == 后续 ClipinCore 必定失败。旧实现用 try? 静默吞错，
        // 用户看到的最终错误会是 "DB 打不开" 而非真正的 root cause（权限/磁盘已满）。
        // 启动阶段直接 fatalError 携带原始 NSError，便于在 Console 中精确定位。
        do {
            try fileManager.createDirectory(atPath: clipinDir.path, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: imageDir, withIntermediateDirectories: true)
        } catch {
            fatalError("❌ Failed to create Clipin storage directories at \(clipinDir.path): \(error)")
        }

        do {
            self.core = try ClipinCore(dbPath: dbPath, imageDir: imageDir)
            print("✅ ClipinCore initialized: \(dbPath)")
        } catch {
            fatalError("❌ Failed to initialize ClipinCore: \(error)")
        }
    }
}
