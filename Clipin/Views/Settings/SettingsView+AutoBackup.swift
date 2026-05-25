import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Auto Backup Tab

    var autoBackupContent: some View {
        VStack(spacing: contentStackSpacing) {
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

            if settings.autoBackupEnabled {
                contentGroup {
                    VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                        backupFolderSection
                        groupDivider
                        backupFrequencySection
                        groupDivider
                        backupStatusSection
                    }
                }
            }
        }
        .alert(
            "Heads up before turning on auto backup",
            isPresented: $showAutoBackupFirstSetupNotice
        ) {
            Button("Cancel", role: .cancel) {
                // 用户拒绝 → toggle 回滚为关
                settings.autoBackupEnabled = false
            }
            Button("I understand, turn on") {
                settings.autoBackupFirstSetupNoticeShown = true
                applyEnableEffects()
            }
        } message: {
            Text("Auto backup writes your full clipboard history—including the original text and image content—to the backup folder. If the folder is in iCloud Drive, that content is uploaded to iCloud. Items from password managers are skipped automatically.")
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
                    .disabled(!AutoBackupService.isICloudDriveAvailable())
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

    // MARK: - Frequency Section

    private var backupFrequencySection: some View {
        settingFieldRow(
            "Frequency",
            description: "Daily is recommended. On Clipboard Change keeps the backup near real-time but uses more network on iCloud Drive."
        ) {
            Picker("", selection: $settings.autoBackupInterval) {
                ForEach(AutoBackupInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .labelsHidden()
            .frame(width: 190)
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

    /// 第一行：状态点 + 主文案
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

    @ViewBuilder
    private var statusIndicatorDot: some View {
        if autoBackup.pausedDueToFailures {
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        } else if autoBackup.lastBackupError != nil {
            Circle().fill(Color.red).frame(width: 7, height: 7)
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
        if autoBackup.lastBackupAt != nil { return ClipinInk.secondary }
        return ClipinInk.tertiary
    }

    /// 第二行：备份文件路径（"Saved to ~/Library/Mobile Documents/com~apple~CloudDocs/Clipin Backups"）
    private var backupLocationLabel: String? {
        if let url = autoBackup.lastBackupURL {
            return String(format: NSLocalizedString("Saved to %@", comment: ""), abbreviatedPath(url.path))
        }
        if let folder = settings.autoBackupFolderPath {
            return String(format: NSLocalizedString("Folder: %@", comment: ""), abbreviatedPath(folder))
        }
        return nil
    }

    /// 第三行：按钮组
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

    /// 30 秒节流：避免用户在 onChange 模式刚自动备份完又手动点一次重复传一份
    private var isJustBackedUp: Bool {
        guard let last = autoBackup.lastBackupAt else { return false }
        return now.timeIntervalSince(last) < 30
    }

    // MARK: - Actions

    private func handleEnableToggle(_ newValue: Bool) {
        if newValue {
            // 首次启用：先弹隐私警示 sheet；用户确认后再真正打开
            if !settings.autoBackupFirstSetupNoticeShown {
                showAutoBackupFirstSetupNotice = true
                return
            }
            applyEnableEffects()
        } else {
            settings.autoBackupEnabled = false
        }
    }

    /// 确认开启后的副作用：先确保 folderPath 可用，再写 enabled=true。
    /// 不在 toggle Binding setter 里直接做——首次启用必须经过隐私警示 sheet。
    ///
    /// 顺序很关键：若先置 enabled=true 再 createDirectory，目录创建失败时会留下
    /// "UI 显示已启用、folderPath=nil、reconfigure 直接 return" 的静默失效——
    /// 违反 CLAUDE.md "不兜底"。失败时保持 enabled=false 让 UI 一致。
    private func applyEnableEffects() {
        if settings.autoBackupFolderPath == nil {
            guard ensureDefaultBackupFolder() else {
                // 已经 showNotice；保持 enabled=false
                return
            }
        }
        settings.autoBackupEnabled = true
    }

    /// "开启 toggle 自动选默认路径" 是合格线，不允许回到"必须用户选路径"形态。
    /// 默认 iCloud Drive/Clipin Backups（可用时），否则 ~/Documents/Clipin Backups。
    /// 返回 true 表示 folderPath 已成功设置；失败时显示 notice 并返回 false。
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
        // x-apple.systempreferences URL 直接跳到 iCloud pane；用户开启 iCloud Drive 后回来再试
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
        // 没有备份记录或备份文件丢失 → 退而打开文件夹
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
