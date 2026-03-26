import SwiftUI

private struct SettingsNotice {
    let text: String
    let isError: Bool
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let core: ClipinCore

    @State private var notice: SettingsNotice?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                generalSection
                privacySection
                retentionSection
                transferSection

                if let notice {
                    noticeView(notice)
                }
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
        .onDisappear {
            dismissTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 26, weight: .semibold))
            Text("Manage the shortcut, privacy, history retention, startup behavior, and transfer tools.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - General

    private var generalSection: some View {
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

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Launch Clipin at login",
                        isOn: Binding(
                            get: { settings.launchAtLoginEnabled },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)

                    if let note = settings.launchAtLoginNote {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("General", systemImage: "gear")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                        .frame(width: 16, alignment: .center)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sensitive content is always excluded")
                            .font(.system(size: 13, weight: .medium))
                        Text("When apps like 1Password or Bitwarden mark content as sensitive, Clipin never records it. This cannot be turned off.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        "Filter out drag-and-drop and app-generated clipboard writes",
                        isOn: Binding(
                            get: { settings.skipTransientContent },
                            set: { settings.skipTransientContent = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                    Text("Skips clipboard entries not triggered by an explicit copy action. Turn on if unintended items keep appearing in your history.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Privacy", systemImage: "hand.raised")
        }
    }

    // MARK: - Retention

    private static let retentionOptions: [(label: String, days: Int)] = [
        ("7 days", 7),
        ("30 days", 30),
        ("90 days", 90),
        ("1 year", 365),
        ("3 years", 1095),
        ("Forever", 0),
    ]

    private static let maxItemsOptions: [(label: String, count: Int)] = [
        ("500", 500),
        ("1K", 1_000),
        ("5K", 5_000),
        ("10K", 10_000),
        ("50K", 50_000),
        ("Unlimited", 0),
    ]

    private var normalizedRetentionDays: Binding<Int> {
        Binding(
            get: {
                let v = settings.retentionDays
                return Self.retentionOptions.map(\.days).contains(v)
                    ? v
                    : Self.retentionOptions.map(\.days).min(by: { abs($0 - v) < abs($1 - v) }) ?? 30
            },
            set: { settings.retentionDays = $0 }
        )
    }

    private var normalizedMaxItems: Binding<Int> {
        Binding(
            get: {
                let v = settings.maxHistoryItems
                return Self.maxItemsOptions.map(\.count).contains(v)
                    ? v
                    : Self.maxItemsOptions.map(\.count).min(by: { abs($0 - v) < abs($1 - v) }) ?? 500
            },
            set: { settings.maxHistoryItems = $0 }
        )
    }

    private var retentionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Keep unpinned history for")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: normalizedRetentionDays) {
                            ForEach(Self.retentionOptions, id: \.days) { option in
                                Text(option.label).tag(option.days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    Text("Pinned items are always preserved.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Max unpinned items")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: normalizedMaxItems) {
                            ForEach(Self.maxItemsOptions, id: \.count) { option in
                                Text(option.label).tag(option.count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                    Text("Oldest unpinned items are trimmed first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Run Cleanup Now") {
                    runCleanup()
                }
                .buttonStyle(.bordered)
            }
            .padding(4)
        } label: {
            Label("Retention", systemImage: "clock.arrow.circlepath")
        }
    }

    // MARK: - Transfer

    private var transferSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export your clipboard history as JSON, or restore from a previous export.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Existing items are kept during import. Duplicates are skipped.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

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

    // MARK: - Notice

    private func noticeView(_ notice: SettingsNotice) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(notice.isError ? Color.red : Color.accentColor)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }

    private func showNotice(_ text: String, isError: Bool = false) {
        notice = SettingsNotice(text: text, isError: isError)
        dismissTask?.cancel()
        guard !isError else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: - Actions

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
}
