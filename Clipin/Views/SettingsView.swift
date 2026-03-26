import SwiftUI

private struct SettingsNotice {
    let text: String
    let isError: Bool
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var autoBackup: AutoBackupService
    let core: ClipinCore

    @Environment(\.colorScheme) private var colorScheme
    @State private var notice: SettingsNotice?
    @State private var dismissTask: Task<Void, Never>?
    // "Last backup X ago" 每分钟刷新用的参考时间
    @State private var now: Date = .now
    @State private var tickTimer: Timer?

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            windowBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    generalSection
                    privacySection
                    retentionSection
                    transferSection
                    autoBackupSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 620, height: 720)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice {
                noticeView(notice)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
            tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in now = .now }
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
            notice = nil          // 防止 error notice 跨窗口生命周期残留
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(glass.searchInnerTint)
                        )
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 28, weight: .semibold))
                    Text("Manage the shortcut, privacy, history retention, startup behavior, and transfer tools.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                headerBadge(systemImage: "circle.lefthalf.filled", title: settings.appearanceOverride.displayName)
                headerBadge(systemImage: "swatchpalette", title: settings.visualTheme.displayName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(sectionBackground(shadowRadius: 26, shadowY: 12))
    }

    // MARK: - General

    private var generalSection: some View {
        sectionCard("General", systemImage: "gear") {
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

                HStack(alignment: .firstTextBaseline) {
                    Text("Appearance")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Picker("", selection: $settings.appearanceOverride) {
                        ForEach(AppearanceOverride.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Theme")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: $settings.visualTheme) {
                            ForEach(VisualTheme.allCases, id: \.self) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    Text("Changes the panel tint while keeping native materials.")
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
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        sectionCard("Privacy", systemImage: "hand.raised", accent: .green) {
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
        sectionCard("Retention", systemImage: "clock.arrow.circlepath", accent: .orange) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Keep unpinned history for")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Picker("", selection: normalizedRetentionDays) {
                            ForEach(Self.retentionOptions, id: \.days) { option in
                                Text(LocalizedStringKey(option.label)).tag(option.days)
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
                                Text(LocalizedStringKey(option.label)).tag(option.count)
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
        }
    }

    // MARK: - Transfer

    private var transferSection: some View {
        sectionCard("Transfer", systemImage: "arrow.left.arrow.right.circle", accent: .blue) {
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
        }
    }

    // MARK: - Auto Backup

    private var autoBackupSection: some View {
        sectionCard("Auto Backup", systemImage: "icloud.and.arrow.up", accent: .cyan) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatically export clipboard history to a folder on a schedule.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Saves as clipin-backup.json. Put it in iCloud Drive, Dropbox, or any folder.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Toggle("Enable auto backup", isOn: $settings.autoBackupEnabled)

                if settings.autoBackupEnabled {
                    Divider()

                    // 文件夹选择
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Backup folder")
                            .font(.system(size: 12, weight: .medium))

                        if let path = settings.autoBackupFolderPath {
                            Text(abbreviatedPath(path))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        HStack(spacing: 8) {
                            Button(settings.autoBackupFolderPath == nil ? "Choose Folder…" : "Change…") {
                                chooseBackupFolder()
                            }
                            .buttonStyle(.bordered)

                            Button("Use iCloud Drive") { useICloudDrive() }
                                .buttonStyle(.bordered)
                        }
                    }

                    // 间隔选择
                    HStack {
                        Text("Frequency")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Picker("", selection: $settings.autoBackupInterval) {
                            ForEach(AutoBackupInterval.allCases, id: \.self) { interval in
                                Text(interval.displayName).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    // 状态行
                    HStack(spacing: 8) {
                        if let error = autoBackup.lastBackupError {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("Backup failed: \(error)")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        } else if let date = autoBackup.lastBackupAt {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            // now 每分钟更新，驱动相对时间字符串重新计算
                            Text("Last backup: \(relativeString(from: date, to: now))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                            Text("No backup yet")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        if settings.autoBackupFolderPath != nil {
                            Button("Backup Now") { autoBackup.backupNow() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var windowBackdrop: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay(
                LinearGradient(
                    colors: [glass.shellTintTop, glass.shellTintBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                LinearGradient(
                    colors: [glass.shellWash, Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.14))
                    .frame(width: 260, height: 260)
                    .blur(radius: 80)
                    .offset(x: 70, y: -120)
            }
            .overlay(alignment: .bottomLeading) {
                Circle()
                    .fill(glass.chromeTint.opacity(colorScheme == .dark ? 0.65 : 1.0))
                    .frame(width: 320, height: 320)
                    .blur(radius: 100)
                    .offset(x: -90, y: 120)
            }
            .ignoresSafeArea()
    }

    private func headerBadge(systemImage: String, title: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule(style: .continuous).fill(glass.keycapTint))
            )
    }

    private func sectionCard<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        accent: Color = .accentColor,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: ClipinChrome.rowCornerRadius, style: .continuous)
                    .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    .overlay(
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                    )
                    .frame(width: 32, height: 32)

                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                Spacer()
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(sectionBackground())
    }

    private func sectionBackground(
        shadowRadius: CGFloat = 20,
        shadowY: CGFloat = 10
    ) -> some View {
        RoundedRectangle(cornerRadius: ClipinChrome.sectionCornerRadius, style: .continuous)
            .fill(.thinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: ClipinChrome.sectionCornerRadius, style: .continuous)
                    .fill(glass.detailTint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ClipinChrome.sectionCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: shadowRadius, y: shadowY)
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Backup Folder"
        panel.message = "Choose a folder for the clipin-backup.json file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.autoBackupFolderPath = url.path
    }

    private func useICloudDrive() {
        // iCloud Drive 在非沙盒 app 中可直接访问的标准路径
        let icloudURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Clipin")
        do {
            try FileManager.default.createDirectory(at: icloudURL, withIntermediateDirectories: true)
            settings.autoBackupFolderPath = icloudURL.path
        } catch {
            showNotice("Cannot create iCloud Drive folder: \(error.localizedDescription)", isError: true)
        }
    }

    private func relativeString(from date: Date, to now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: now)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                        .fill(glass.searchInnerTint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.searchCornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18), lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
    }

    private func showNotice(_ text: String, isError: Bool = false) {
        notice = SettingsNotice(text: text, isError: isError)
        dismissTask?.cancel()
        guard !isError else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: - Actions

    private func runCleanup() {
        // CleanupService.runNow() 是 @MainActor，无法脱离主线程；
        // 用 Task {} 保持异步语义，避免阻塞当前调用帧
        Task {
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
