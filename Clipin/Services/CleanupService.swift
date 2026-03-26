import Foundation

struct CleanupResult {
    let removedByAge: Int
    let removedByCount: Int

    var totalRemoved: Int {
        removedByAge + removedByCount
    }
}

struct CleanupService {
    let core: ClipinCore
    let settings: SettingsStore

    @MainActor
    func runNow(referenceDate: Date = .now) throws -> CleanupResult {
        let retentionDays = settings.retentionDays
        let maxItems = settings.maxHistoryItems
        let core = self.core

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
    }
}
