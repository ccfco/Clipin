import SwiftUI

extension SettingsView {

    // MARK: - Actions

    func runCleanup() {
        guard activeOperation == nil else { return }
        activeOperation = .cleanup
        Task { @MainActor in
            defer { activeOperation = nil }
            do {
                let result = try await cleanupService.runNow()
                NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
                if result.totalRemoved == 0 {
                    showNotice(NSLocalizedString("Nothing needed cleanup. Your history already fits the current policy.", comment: ""))
                } else {
                    showNotice(
                        localized(
                            "Removed %d items (%d by age, %d by count).",
                            result.totalRemoved,
                            result.removedByAge,
                            result.removedByCount
                        )
                    )
                }
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    func exportArchive() {
        guard activeOperation == nil else { return }
        activeOperation = .exportArchive
        Task { @MainActor in
            defer { activeOperation = nil }
            do {
                let result = try await ArchiveService.exportArchive(core: core)
                showNotice(
                    localized(
                        "Exported %d items to %@.",
                        result.exportedCount,
                        result.url.lastPathComponent
                    ) + exportSkippedSuffix(result.skippedCount)
                )
            } catch ArchiveError.cancelled {
                return
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    func importArchive() {
        guard activeOperation == nil else { return }
        activeOperation = .importArchive
        Task { @MainActor in
            defer { activeOperation = nil }
            do {
                let result = try await ArchiveService.importArchive(core: core)
                let cleanup = try await cleanupService.runNow()
                NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
                let cleanupSuffix = cleanup.totalRemoved > 0
                    ? " " + localized("Cleanup removed %d older items.", cleanup.totalRemoved)
                    : ""
                showNotice(
                    localized(
                        "Imported %d items from %@.",
                        result.importedCount,
                        result.url.lastPathComponent
                    ) + importSkippedSuffix(
                        missingImageCount: result.skippedMissingImageCount,
                        duplicateCount: result.skippedDuplicateCount,
                        failedRepresentationCount: result.failedRepresentationCount
                    ) + cleanupSuffix
                )
            } catch ArchiveError.cancelled {
                return
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Suffix Helpers

    private func exportSkippedSuffix(_ skippedCount: Int) -> String {
        skippedCount > 0
            ? " " + localized("Skipped %d items with missing image data.", skippedCount)
            : ""
    }

    private func importSkippedSuffix(
        missingImageCount: Int,
        duplicateCount: Int,
        failedRepresentationCount: Int
    ) -> String {
        var parts: [String] = []
        if missingImageCount > 0 {
            parts.append(localized("Skipped %d items with missing image data.", missingImageCount))
        }
        if duplicateCount > 0 {
            parts.append(localized("Skipped %d duplicate items.", duplicateCount))
        }
        if failedRepresentationCount > 0 {
            parts.append(localized("Dropped %d corrupt format representations.", failedRepresentationCount))
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }
}
