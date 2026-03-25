import SwiftUI

private struct SettingsNotice {
    let text: String
    let isError: Bool
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let core: ClipinCore

    @State private var notice: SettingsNotice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                activationSection
                retentionSection
                transferSection

                if let notice {
                    noticeView(notice)
                } else if let note = settings.launchAtLoginNote {
                    infoRow(text: note)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 26, weight: .semibold))
            Text("Manage the shortcut, history retention, startup behavior, and transfer tools.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var activationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Global shortcut")
                        .font(.system(size: 13, weight: .medium))

                    HStack(spacing: 10) {
                        ShortcutRecorder(
                            shortcut: Binding(
                                get: { settings.shortcut },
                                set: { settings.shortcut = $0 }
                            )
                        )
                        .frame(width: 180, height: 34)

                        Button("Reset") {
                            settings.shortcut = .default
                            showNotice("Shortcut reset to \(settings.shortcut.displayString).")
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Click the field and press the new shortcut. At least one modifier key is required.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Toggle(
                    "Launch Clipin at login",
                    isOn: Binding(
                        get: { settings.launchAtLoginEnabled },
                        set: { settings.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
            }
            .padding(4)
        } label: {
            Label("Activation", systemImage: "keyboard")
        }
    }

    private var retentionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Stepper(value: Binding(
                    get: { settings.retentionDays },
                    set: { settings.retentionDays = $0 }
                ), in: 1...365) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Keep unpinned history for \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .medium))
                        Text("Pinned items are preserved.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(value: Binding(
                    get: { settings.maxHistoryItems },
                    set: { settings.maxHistoryItems = $0 }
                ), in: 50...5_000, step: 50) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cap unpinned history at \(settings.maxHistoryItems) items")
                            .font(.system(size: 13, weight: .medium))
                        Text("Oldest unpinned items are trimmed first.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Button("Run Cleanup Now") {
                    runCleanup()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(4)
        } label: {
            Label("Retention", systemImage: "clock.arrow.circlepath")
        }
    }

    private var transferSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Text("Export and import your clipboard history as JSON. Image clips are embedded directly into the archive.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Export JSON…") {
                        exportArchive()
                    }
                    .buttonStyle(.bordered)

                    Button("Import JSON…") {
                        importArchive()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(4)
        } label: {
            Label("Transfer", systemImage: "arrow.left.arrow.right.circle")
        }
    }

    private func noticeView(_ notice: SettingsNotice) -> some View {
        infoRow(
            text: notice.text,
            accent: notice.isError ? .red : .accentColor
        )
    }

    private func infoRow(text: String, accent: Color = .secondary) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(accent)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func runCleanup() {
        do {
            let result = try CleanupService(core: core, settings: settings).runNow()
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
            if result.totalRemoved == 0 {
                showNotice("Nothing needed cleanup. Your history already fits the current policy.")
            } else {
                showNotice("Removed \(result.totalRemoved) items (\(result.removedByAge) by age, \(result.removedByCount) by count).")
            }
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func exportArchive() {
        do {
            let result = try ArchiveService.exportArchive(core: core)
            showNotice("Exported \(result.exportedCount) items to \(result.url.lastPathComponent)." + skippedSuffix(result.skippedCount))
        } catch ArchiveError.cancelled {
            return
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func importArchive() {
        do {
            let result = try ArchiveService.importArchive(core: core)
            let cleanup = try CleanupService(core: core, settings: settings).runNow()
            NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
            let cleanupSuffix = cleanup.totalRemoved > 0 ? " Cleanup removed \(cleanup.totalRemoved) older items." : ""
            showNotice("Imported \(result.importedCount) items from \(result.url.lastPathComponent)." + skippedSuffix(result.skippedCount) + cleanupSuffix)
        } catch ArchiveError.cancelled {
            return
        } catch {
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func skippedSuffix(_ skippedCount: Int) -> String {
        skippedCount > 0 ? " Skipped \(skippedCount) items with missing image data." : ""
    }

    private func showNotice(_ text: String, isError: Bool = false) {
        notice = SettingsNotice(text: text, isError: isError)
    }
}
