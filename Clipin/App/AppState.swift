import AppKit
import SwiftUI

/// 全局应用状态
/// ClipinCore 内部用 Mutex 保证线程安全，不需要 @MainActor
final class AppState: ObservableObject, @unchecked Sendable {
    static let shared = AppState()

    let core: ClipinCore

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clipinDir = appSupport.appendingPathComponent("Clipin")
        let dbPath = clipinDir.appendingPathComponent("clipin.db").path
        let imageDir = clipinDir.appendingPathComponent("images").path

        try? FileManager.default.createDirectory(atPath: clipinDir.path, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: imageDir, withIntermediateDirectories: true)

        do {
            self.core = try ClipinCore(dbPath: dbPath, imageDir: imageDir)
            print("✅ ClipinCore initialized: \(dbPath)")
        } catch {
            fatalError("❌ Failed to initialize ClipinCore: \(error)")
        }
    }
}
