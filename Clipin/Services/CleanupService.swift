import Combine
import Foundation

struct CleanupResult: Sendable, Codable {
    let removedByAge: Int
    let removedByCount: Int

    var totalRemoved: Int {
        removedByAge + removedByCount
    }
}

/// 按用户配置的 retentionDays / maxHistoryItems 清理未 pin 历史。
/// 当前只在用户手动触发 + 导入归档后自动跑——不维护后台定时器。
///
/// 已是 ObservableObject：UI 需要观察 lastRunAt / lastResult 显示"规则在跑"的证据，
/// 否则用户改完 picker 没法判断设置是否真的生效（CLAUDE.md「不沉默成功」红线）。
@MainActor
final class CleanupService: ObservableObject {
    let core: ClipinCore
    let settings: SettingsStore

    /// 上次清理的结果——为 nil 表示从未跑过（不持久化具体数字到 UserDefaults，
    /// 数字一两天就过时无意义；只持久化 timestamp 让用户知道"多久前最近一次跑过"）。
    @Published private(set) var lastResult: CleanupResult?
    @Published private(set) var lastRunAt: Date?

    private static let lastRunAtKey = "cleanup.lastRunAt"

    init(core: ClipinCore, settings: SettingsStore) {
        self.core = core
        self.settings = settings
        self.lastRunAt = UserDefaults.standard.object(forKey: Self.lastRunAtKey) as? Date
    }

    func runNow(referenceDate: Date = .now) async throws -> CleanupResult {
        let retentionDays = settings.retentionDays
        let maxItems = settings.maxHistoryItems
        let core = self.core

        let result = try await Task.detached(priority: .utility) {
            // retentionDays == 0 表示永久保留，跳过按时间清理
            let removedByAge: Int
            if retentionDays > 0 {
                let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: referenceDate)
                    ?? referenceDate
                let cutoffMillis = Int64(cutoffDate.timeIntervalSince1970 * 1000)
                removedByAge = Int(try core.clearUnpinnedBefore(timestamp: cutoffMillis))
            } else {
                removedByAge = 0
            }

            try Task.checkCancellation()

            // maxItems == 0 表示不限数量，跳过按数量清理
            let removedByCount: Int
            if maxItems > 0 {
                removedByCount = Int(try core.trimUnpinned(keepLatest: Int32(maxItems)))
            } else {
                removedByCount = 0
            }

            return CleanupResult(
                removedByAge: removedByAge,
                removedByCount: removedByCount
            )
        }.value

        let completedAt = Date()
        lastResult = result
        lastRunAt = completedAt
        UserDefaults.standard.set(completedAt, forKey: Self.lastRunAtKey)
        return result
    }
}
