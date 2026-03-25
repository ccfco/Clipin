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
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -settings.retentionDays, to: referenceDate)
            ?? referenceDate
        let cutoffMillis = Int64(cutoffDate.timeIntervalSince1970 * 1000)
        let maxItems = Int32(settings.maxHistoryItems)
        let core = self.core

        let removedByAge = Int(try core.clearUnpinnedBefore(timestamp: cutoffMillis))
        let removedByCount = Int(try core.trimUnpinned(keepLatest: maxItems))

        return CleanupResult(
            removedByAge: removedByAge,
            removedByCount: removedByCount
        )
    }
}
