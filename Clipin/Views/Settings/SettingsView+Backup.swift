import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Backup & Restore Tab

    /// 合并 v4 之前的 Auto Backup + Transfer 两个 tab。结构：
    /// 1. Enable toggle（始终显示）
    /// 2. 启用后：folder / frequency / status / cleanup（折叠在一个 contentGroup 里）
    /// 3. 一次性导入导出（始终显示，独立 contentGroup）
    var backupContent: some View {
        VStack(spacing: contentStackSpacing) {
            autoBackupToggleGroup
            if settings.autoBackupEnabled {
                autoBackupDetailGroup
            }
            transferGroup
        }
        .alert(
            "Heads up before turning on auto backup",
            isPresented: $showAutoBackupFirstSetupNotice
        ) {
            Button("Cancel", role: .cancel) {
                settings.autoBackupEnabled = false
            }
            Button("I understand, turn on") {
                settings.autoBackupFirstSetupNoticeShown = true
                applyEnableEffects()
            }
        } message: {
            Text("Auto backup writes your full clipboard history—including the original text and image content—to the backup folder. If the folder is in iCloud Drive, that content is uploaded to iCloud. Items from password managers are skipped automatically.")
        }
        .sheet(isPresented: $showCleanupSheet) {
            cleanupSheet
        }
    }

    // MARK: - Top-level groups

    private var autoBackupToggleGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                toggleSettingRow(
                    "Enable auto backup",
                    description: "Export history as a .clipin.zip archive on a schedule. Store it in iCloud Drive, Dropbox, or any folder you trust.",
                    isOn: Binding(
                        get: { settings.autoBackupEnabled },
                        set: { handleEnableToggle($0) }
                    )
                )
                if !settings.autoBackupEnabled {
                    Text("Existing backups in the folder are preserved when this is disabled.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.tertiary)
                }
            }
        }
    }

    private var autoBackupDetailGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                backupFolderSection
                groupDivider
                backupFrequencySection
                groupDivider
                backupStatusSection
                if !cleanupCandidates.isEmpty {
                    groupDivider
                    backupCleanupSection
                }
            }
            // 切换 folder/启停时重新扫描；onAppear 也扫一次
            .onAppear(perform: refreshCleanupCandidates)
            .onChange(of: settings.autoBackupFolderPath) { _, _ in refreshCleanupCandidates() }
            .onChange(of: autoBackup.lastBackupAt) { _, _ in refreshCleanupCandidates() }
        }
    }

    private var transferGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                actionRow(
                    "Export clipboard history",
                    description: "Create a one-off .clipin.zip snapshot you can archive or share elsewhere.",
                    buttonTitle: "Export…",
                    busyTitle: "Exporting…",
                    isBusy: activeOperation == .exportArchive,
                    action: exportArchive
                )
                groupDivider
                actionRow(
                    "Import from a backup",
                    description: "Bring items back from a .clipin.zip archive or a legacy JSON export. Existing items stay in place and duplicates are skipped.",
                    buttonTitle: "Import…",
                    busyTitle: "Importing…",
                    isBusy: activeOperation == .importArchive,
                    action: importArchive
                )
            }
        }
    }

    // MARK: - Folder Section

    private var backupFolderSection: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text("Backup folder")
                .font(.system(size: 13, weight: .medium))

            Text(
                settings.autoBackupFolderPath.map(abbreviatedPath)
                    ?? "Choose a destination folder for the backup archive."
            )
            .font(.system(size: 12))
            .foregroundStyle(ClipinInk.secondary)
            .lineLimit(2)
            .truncationMode(.middle)

            HStack(spacing: ClipinChrome.gap) {
                Button(settings.autoBackupFolderPath == nil ? "Choose Folder…" : "Change…") {
                    chooseBackupFolder()
                }
                .buttonStyle(.bordered)

                Button("Use iCloud Drive") { useICloudDrive() }
                    .buttonStyle(.bordered)
                    .disabled(!AutoBackupService.isICloudDriveAvailable() || isCurrentFolderICloudDefault)

                // 当前路径 ≠ 默认路径时显示 "Reset to Default"——避免用户改过路径后回不去
                if shouldShowResetDefault {
                    Button("Reset to Default") { resetBackupFolderToDefault() }
                        .buttonStyle(.bordered)
                }
            }

            if !AutoBackupService.isICloudDriveAvailable() {
                HStack(spacing: ClipinChrome.gap) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.tertiary)
                    Text("iCloud Drive is not enabled.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.tertiary)
                    Button("Open System Settings") { openICloudSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
            }
        }
    }

    /// Reset 按钮显隐：仅当用户已经设置了文件夹路径，且当前路径与"默认"不同
    private var shouldShowResetDefault: Bool {
        guard let current = settings.autoBackupFolderPath else { return false }
        let normalizedCurrent = URL(fileURLWithPath: current, isDirectory: true).standardizedFileURL.path
        let defaultPath = AutoBackupService.computeDefaultBackupFolder().standardizedFileURL.path
        return normalizedCurrent != defaultPath
    }

    /// iCloud 按钮的禁用判定：已经在 iCloud 默认路径上时不重复触发
    private var isCurrentFolderICloudDefault: Bool {
        guard let current = settings.autoBackupFolderPath,
              let icloud = AutoBackupService.iCloudBackupFolder() else { return false }
        return URL(fileURLWithPath: current, isDirectory: true).standardizedFileURL.path
            == icloud.standardizedFileURL.path
    }

    // MARK: - Frequency Section

    private var backupFrequencySection: some View {
        settingFieldRow(
            "Frequency",
            description: "Daily is recommended. Hourly keeps the archive fresher at the cost of more uploads on iCloud Drive."
        ) {
            Picker("", selection: $settings.autoBackupInterval) {
                ForEach(AutoBackupInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - Status Section

    private var backupStatusSection: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text("Backup status")
                .font(.system(size: 13, weight: .medium))

            contentGroup(padding: ClipinChrome.groupGap) {
                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    statusPrimaryRow
                    if let location = backupLocationLabel {
                        Text(location)
                            .font(.system(size: 11))
                            .foregroundStyle(ClipinInk.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    statusActionRow
                }
            }
        }
    }

    private var statusPrimaryRow: some View {
        HStack(spacing: ClipinChrome.gap) {
            statusIndicatorDot
            Text(statusPrimaryText)
                .font(.system(size: 11))
                .foregroundStyle(statusPrimaryColor)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// partial backup（skippedCount > 0）= 数据不完整的"准成功"——必须橙色 warning
    /// 提示用户某些条目（一般是图片文件丢失）没进归档，依赖此备份恢复时会缺数据。
    private var isPartialBackup: Bool {
        autoBackup.lastBackupAt != nil
            && autoBackup.lastBackupSkipped > 0
            && autoBackup.lastBackupError == nil
            && !autoBackup.pausedDueToFailures
    }

    @ViewBuilder
    private var statusIndicatorDot: some View {
        if autoBackup.pausedDueToFailures {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if autoBackup.lastBackupError != nil {
            Circle().fill(Color.red).frame(width: 7, height: 7)
        } else if isPartialBackup {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if autoBackup.lastBackupAt != nil {
            Circle().fill(Color.green).frame(width: 7, height: 7)
        } else {
            Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
    }

    private var statusPrimaryText: String {
        if autoBackup.pausedDueToFailures {
            return NSLocalizedString("Auto backup paused after repeated failures.", comment: "")
        }
        if let error = autoBackup.lastBackupError {
            return String(format: NSLocalizedString("Backup failed: %@", comment: ""), error)
        }
        if let date = autoBackup.lastBackupAt {
            let timeText = relativeString(from: date, to: now)
            // partial：时间 + skipped count，明确告知用户"备份完成但不完整"
            if isPartialBackup {
                return String(
                    format: NSLocalizedString(
                        "Last backup: %@ · %d items skipped (missing image files)",
                        comment: ""
                    ),
                    timeText,
                    autoBackup.lastBackupSkipped
                )
            }
            if autoBackup.lastBackupSize > 0 {
                let sizeText = ByteCountFormatter.string(fromByteCount: autoBackup.lastBackupSize, countStyle: .file)
                return String(format: NSLocalizedString("Last backup: %@ · %@", comment: ""), timeText, sizeText)
            }
            return String(format: NSLocalizedString("Last backup: %@", comment: ""), timeText)
        }
        return NSLocalizedString("No backup yet", comment: "")
    }

    private var statusPrimaryColor: Color {
        if autoBackup.pausedDueToFailures { return .orange }
        if autoBackup.lastBackupError != nil { return .red }
        if isPartialBackup { return .orange }
        if autoBackup.lastBackupAt != nil { return ClipinInk.secondary }
        return ClipinInk.tertiary
    }

    private var backupLocationLabel: String? {
        if let url = autoBackup.lastBackupURL {
            return String(format: NSLocalizedString("Saved to %@", comment: ""), abbreviatedPath(url.path))
        }
        if let folder = settings.autoBackupFolderPath {
            return String(format: NSLocalizedString("Folder: %@", comment: ""), abbreviatedPath(folder))
        }
        return nil
    }

    @ViewBuilder
    private var statusActionRow: some View {
        HStack(spacing: ClipinChrome.gap) {
            Spacer(minLength: 0)

            if autoBackup.pausedDueToFailures {
                Button("Resume") { autoBackup.resume() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Button {
                showBackupInFinder()
            } label: {
                Text("Show in Finder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(autoBackup.lastBackupURL == nil && settings.autoBackupFolderPath == nil)

            if settings.autoBackupFolderPath != nil {
                Button {
                    autoBackup.backupNow()
                } label: {
                    progressButtonLabel(
                        title: backupNowButtonTitle,
                        isBusy: autoBackup.isBackingUp
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(autoBackup.isBackingUp || isJustBackedUp)
            }
        }
    }

    private var backupNowButtonTitle: LocalizedStringKey {
        if autoBackup.isBackingUp { return "Backing Up…" }
        if isJustBackedUp { return "Backed up just now" }
        return "Backup Now"
    }

    /// 30 秒节流：避免用户刚自动备份完又手动点一次重复传一份
    private var isJustBackedUp: Bool {
        guard let last = autoBackup.lastBackupAt else { return false }
        return now.timeIntervalSince(last) < 30
    }

    // MARK: - Cleanup Section

    private var backupCleanupSection: some View {
        let count = cleanupCandidates.count
        let totalSize = cleanupCandidates.reduce(into: Int64(0)) { $0 += $1.size }
        let sizeText = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        return VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text("Legacy backup files")
                .font(.system(size: 13, weight: .medium))
            Text(
                String(
                    format: NSLocalizedString("Found %d legacy file(s) totaling %@ in this folder. These are old JSON backups or archives from other Macs.", comment: ""),
                    count, sizeText
                )
            )
            .font(.system(size: 11))
            .foregroundStyle(ClipinInk.secondary)

            HStack(spacing: ClipinChrome.gap) {
                Spacer(minLength: 0)
                Button("Review & Clean Up…") { showCleanupSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(activeOperation == .cleanupBackupFolder)
            }
        }
    }

    private var cleanupSheet: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            Text("Clean up legacy backups")
                .font(.system(size: 16, weight: .semibold))
            Text("These files were left over by previous versions or other devices and will be deleted permanently. Your current backup and its safety net are not affected.")
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    ForEach(cleanupCandidates) { candidate in
                        cleanupRow(candidate)
                    }
                }
            }
            .frame(maxHeight: 280)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showCleanupSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(
                    String(format: NSLocalizedString("Delete %d File(s)", comment: ""), cleanupCandidates.count),
                    role: .destructive
                ) {
                    confirmCleanup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeOperation == .cleanupBackupFolder || cleanupCandidates.isEmpty)
            }
        }
        .padding(ClipinChrome.groupGap * 2)
        .frame(width: 520)
    }

    private func cleanupRow(_ candidate: BackupCleanupService.Candidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ClipinChrome.gap) {
            Image(systemName: candidate.reason == .legacyJSON ? "doc.text" : "externaldrive.badge.icloud")
                .foregroundStyle(ClipinInk.tertiary)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(candidate.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(cleanupRowSubtitle(candidate))
                    .font(.system(size: 10))
                    .foregroundStyle(ClipinInk.tertiary)
            }
            Spacer(minLength: 0)
            Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(ClipinInk.tertiary)
        }
    }

    private func cleanupRowSubtitle(_ candidate: BackupCleanupService.Candidate) -> String {
        let reasonLabel: String = {
            switch candidate.reason {
            case .legacyJSON: return NSLocalizedString("Legacy JSON backup", comment: "")
            case .foreignHost: return NSLocalizedString("From another Mac", comment: "")
            }
        }()
        guard let modifiedAt = candidate.modifiedAt else { return reasonLabel }
        let timeText = relativeString(from: modifiedAt, to: now)
        return "\(reasonLabel) · \(timeText)"
    }

    private func refreshCleanupCandidates() {
        guard let folderPath = settings.autoBackupFolderPath else {
            cleanupCandidates = []
            return
        }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        // 扫描失败 ≠ 无遗留：必须正面暴露错误避免误导用户。folderMissing 这种
        // "目录正常缺失"（用户改了路径还没同步、或 iCloud 离线）silently 清空候选
        // 即可，不打扰；真正的 enumerationFailed（权限/IO）才 showNotice。
        do {
            cleanupCandidates = try BackupCleanupService.scan(
                folderURL: folderURL,
                currentHostSlug: AutoBackupService.currentHostnameSlug
            )
        } catch BackupCleanupService.ScanError.folderMissing {
            cleanupCandidates = []
        } catch {
            cleanupCandidates = []
            showNotice(error.localizedDescription, isError: true)
        }
    }

    private func confirmCleanup() {
        guard activeOperation == nil else { return }
        let snapshot = cleanupCandidates
        guard !snapshot.isEmpty else { return }
        activeOperation = .cleanupBackupFolder
        showCleanupSheet = false
        Task { @MainActor in
            defer { activeOperation = nil }
            let deleted = BackupCleanupService.delete(snapshot)
            refreshCleanupCandidates()
            if deleted == snapshot.count {
                showNotice(localized("Removed %d legacy backup file(s).", deleted))
            } else {
                showNotice(
                    localized(
                        "Removed %d of %d files. The rest could not be deleted—see Console for details.",
                        deleted, snapshot.count
                    ),
                    isError: deleted == 0
                )
            }
        }
    }

    // MARK: - Actions

    private func handleEnableToggle(_ newValue: Bool) {
        if newValue {
            if !settings.autoBackupFirstSetupNoticeShown {
                showAutoBackupFirstSetupNotice = true
                return
            }
            applyEnableEffects()
        } else {
            settings.autoBackupEnabled = false
        }
    }

    /// 顺序：先确保 folderPath 可用，再写 enabled=true。
    /// 反过来会留下"UI 显示已启用、folderPath=nil、reconfigure 直接 return"的静默失效。
    private func applyEnableEffects() {
        if settings.autoBackupFolderPath == nil {
            guard ensureDefaultBackupFolder() else { return }
        }
        settings.autoBackupEnabled = true
    }

    @discardableResult
    private func ensureDefaultBackupFolder() -> Bool {
        let folder = AutoBackupService.computeDefaultBackupFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            settings.autoBackupFolderPath = folder.path
            return true
        } catch {
            showNotice(
                String(format: NSLocalizedString("Cannot create backup folder: %@", comment: ""), error.localizedDescription),
                isError: true
            )
            return false
        }
    }

    private func resetBackupFolderToDefault() {
        let folder = AutoBackupService.computeDefaultBackupFolder()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            settings.autoBackupFolderPath = folder.path
            showNotice(
                String(format: NSLocalizedString("Backup folder reset to %@.", comment: ""), abbreviatedPath(folder.path))
            )
        } catch {
            showNotice(
                String(format: NSLocalizedString("Cannot create backup folder: %@", comment: ""), error.localizedDescription),
                isError: true
            )
        }
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Choose Backup Folder", comment: "")
        panel.message = NSLocalizedString("Choose a folder for the Clipin backup archive.", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.autoBackupFolderPath = url.path
    }

    private func useICloudDrive() {
        guard let icloudURL = AutoBackupService.iCloudBackupFolder() else {
            showNotice(
                NSLocalizedString("iCloud Drive is not enabled. Enable it in System Settings first.", comment: ""),
                isError: true
            )
            return
        }
        do {
            try FileManager.default.createDirectory(at: icloudURL, withIntermediateDirectories: true)
            settings.autoBackupFolderPath = icloudURL.path
        } catch {
            showNotice(
                String(format: NSLocalizedString("Cannot create iCloud Drive folder: %@", comment: ""), error.localizedDescription),
                isError: true
            )
        }
    }

    private func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud") {
            openExternalURL(url)
        }
    }

    private func showBackupInFinder() {
        if let url = autoBackup.lastBackupURL,
           FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard let folderPath = settings.autoBackupFolderPath else { return }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            NSWorkspace.shared.open(folderURL)
        } else {
            showNotice(
                NSLocalizedString("Backup folder does not exist.", comment: ""),
                isError: true
            )
        }
    }
}
