import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Storage Tab
    //
    // v5: Retention（保留多久）+ Auto Backup（自动备份）+ Transfer（一次性导入导出）
    // 合并为单一 Storage tab，自上而下贯穿"保多久 → 怎么归档 → 一次性搬运"心智链路。
    // 原生 grouped Form：每段一个 Section，自带卡片背景；不再自绘 contentGroup / surface。
    @ViewBuilder
    var storageContent: some View {
        retentionSection
        autoBackupToggleSection
        if settings.autoBackupEnabled {
            backupFolderFormSection
            backupFrequencyStatusSection
            if !cleanupCandidates.isEmpty {
                backupCleanupFormSection
            }
        }
        transferSection
    }

    // MARK: - Auto Backup toggle

    private var autoBackupToggleSection: some View {
        Section("Auto Backup") {
            toggleRow(
                "Enable auto backup",
                "Export history as a .clipin.zip archive on a schedule. Store it in iCloud Drive, Dropbox, or any folder you trust.",
                isOn: Binding(
                    get: { settings.autoBackupEnabled },
                    set: { handleEnableToggle($0) }
                )
            )
            if !settings.autoBackupEnabled {
                Text("Existing backups in the folder are preserved when this is disabled.")
                    .settingsCaption(.tertiary)
            }
        }
        // alert / sheet 挂在常驻 Section 上（toggle 永远存在，detail 组随 enabled 出现/消失）。
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

    // MARK: - Folder Section

    private var backupFolderFormSection: some View {
        Section("Backup folder") {
            backupFolderContent
        }
        // 切换 folder/启停时重新扫描遗留文件；onAppear 也扫一次
        .onAppear(perform: refreshCleanupCandidates)
        .onChange(of: settings.autoBackupFolderPath) { _, _ in refreshCleanupCandidates() }
        .onChange(of: autoBackup.lastBackupAt) { _, _ in refreshCleanupCandidates() }
    }

    private var backupFolderContent: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text(
                settings.autoBackupFolderPath.map(abbreviatedPath)
                    ?? "Choose a destination folder for the backup archive."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: ClipinChrome.gap) {
                Button(settings.autoBackupFolderPath == nil ? "Choose Folder…" : "Change…") {
                    chooseBackupFolder()
                }

                // 默认 = iCloud Backups (if iCloud 可用) / ~/Documents/Clipin Backups。
                // 永远显示提升发现性；已在默认路径时 disabled。
                Button("Use Default Folder") { resetBackupFolderToDefault() }
                    .disabled(AutoBackupService.isDefaultBackupFolder(settings.autoBackupFolderPath))

                Button("Use iCloud Drive") { useICloudDrive() }
                    .disabled(
                        !AutoBackupService.isICloudDriveAvailable()
                            || AutoBackupService.isICloudBackupFolder(settings.autoBackupFolderPath)
                    )
            }

            defaultFolderHint

            if !AutoBackupService.isICloudDriveAvailable() {
                iCloudUnavailableCallout
            }
        }
    }

    /// iCloud 不可用提示——orange callout 风格，跟 backup paused/partial 同等地位。
    private var iCloudUnavailableCallout: some View {
        HStack(alignment: .firstTextBaseline, spacing: ClipinChrome.gap) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text("iCloud Drive is not enabled")
                    .font(.system(size: 12, weight: .medium))
                Text("Backups will be saved locally. Enable iCloud Drive in System Settings to sync across Macs.")
                    .settingsCaption()
            }

            Spacer(minLength: 0)

            Button("Open System Settings…") { openICloudSettings() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(ClipinChrome.gap)
        .background(
            RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.5)
        )
    }

    /// 默认文件夹位置提示：把动态的"默认 = iCloud 或 Documents"显式化。
    private var defaultFolderHint: some View {
        let defaultURL = AutoBackupService.computeDefaultBackupFolder()
        let isICloud = AutoBackupService.isICloudBackupFolder(defaultURL.path)
        let icon = isICloud ? "icloud" : "folder"
        let label = isICloud
            ? String(format: NSLocalizedString("Default: iCloud Drive · %@", comment: ""), abbreviatedPath(defaultURL.path))
            : String(format: NSLocalizedString("Default: %@", comment: ""), abbreviatedPath(defaultURL.path))
        return HStack(spacing: ClipinChrome.gap) {
            Image(systemName: icon)
                .settingsCaption(.tertiary)
            Text(label)
                .settingsCaption(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - Frequency + Status Section

    private var backupFrequencyStatusSection: some View {
        Section {
            Picker(selection: $settings.autoBackupInterval) {
                ForEach(AutoBackupInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            } label: {
                rowLabel(
                    "Frequency",
                    "Daily is recommended. Hourly keeps the archive fresher at the cost of more uploads on iCloud Drive."
                )
            }

            backupStatusContent
        }
    }

    private var backupStatusContent: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            statusPrimaryRow
            if let location = backupLocationLabel {
                Text(location)
                    .settingsCaption(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            statusActionRow
        }
    }

    private var statusPrimaryRow: some View {
        HStack(spacing: ClipinChrome.gap) {
            statusIndicatorDot
            Text(statusPrimaryText)
                .font(.caption)
                .foregroundStyle(statusPrimaryColor)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// partial backup（skippedCount > 0）= 数据不完整的"准成功"——必须橙色 warning。
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
        if autoBackup.lastBackupAt != nil { return .secondary }
        return .secondary
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
                    .controlSize(.small)
            }

            Button {
                showBackupInFinder()
            } label: {
                Text("Show in Finder")
            }
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

    // MARK: - Transfer Section

    private var transferSection: some View {
        Section("Transfer") {
            actionRow(
                "Export clipboard history",
                description: "Create a one-off .clipin.zip snapshot you can archive or share elsewhere.",
                buttonTitle: "Export…",
                busyTitle: "Exporting…",
                isBusy: activeOperation == .exportArchive,
                action: exportArchive
            )
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

    // MARK: - Cleanup Section

    private var backupCleanupFormSection: some View {
        Section("Legacy backup files") {
            backupCleanupContent
        }
    }

    private var backupCleanupContent: some View {
        let count = cleanupCandidates.count
        let totalSize = cleanupCandidates.reduce(into: Int64(0)) { $0 += $1.size }
        let sizeText = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        return VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text(
                String(
                    format: NSLocalizedString("Found %d legacy file(s) totaling %@ in this folder. These are old JSON backups or archives from other Macs.", comment: ""),
                    count, sizeText
                )
            )
            .settingsCaption()
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: ClipinChrome.gap) {
                Spacer(minLength: 0)
                Button("Review & Clean Up…") {
                    cleanupSelection = Set(cleanupCandidates.map(\.id))
                    showCleanupSheet = true
                }
                .controlSize(.small)
                .disabled(activeOperation == .cleanupBackupFolder)
            }
        }
    }

    /// 备份是用户安全网，CLAUDE.md 红线："备份是用户安全网，自动决策必出错"——
    /// 清理 sheet 必须让用户精细决定。默认全选 + 类型快速过滤 + 单行 toggle。
    private var cleanupSheet: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            Text("Clean up legacy backups")
                .font(.system(size: 16, weight: .semibold))
            Text("These files were left over by previous versions or other devices and will be deleted permanently. Your current backup and its safety net are not affected.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            cleanupBulkSelectionBar

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
                Button("Cancel", role: .cancel) {
                    showCleanupSheet = false
                    cleanupSelection.removeAll()
                }
                .keyboardShortcut(.cancelAction)

                Button(
                    String(format: NSLocalizedString("Delete %d File(s)", comment: ""), cleanupSelection.count),
                    role: .destructive
                ) {
                    confirmCleanup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(activeOperation == .cleanupBackupFolder || cleanupSelection.isEmpty)
            }
        }
        .padding(ClipinChrome.groupGap * 2)
        .frame(width: 520)
    }

    private var cleanupBulkSelectionBar: some View {
        let allIds = Set(cleanupCandidates.map(\.id))
        let legacyIds = Set(cleanupCandidates.filter { $0.reason == .legacyJSON }.map(\.id))
        let foreignIds = Set(cleanupCandidates.filter { $0.reason == .foreignHost }.map(\.id))
        let isAllSelected = !allIds.isEmpty && cleanupSelection == allIds
        return HStack(spacing: ClipinChrome.gap) {
            Toggle(isOn: Binding(
                get: { isAllSelected },
                set: { cleanupSelection = $0 ? allIds : [] }
            )) {
                Text(
                    String(format: NSLocalizedString("Select all (%d)", comment: ""), allIds.count)
                )
                .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            if !legacyIds.isEmpty {
                Button(String(format: NSLocalizedString("Only legacy JSON (%d)", comment: ""), legacyIds.count)) {
                    cleanupSelection = legacyIds
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            if !foreignIds.isEmpty {
                Button(String(format: NSLocalizedString("Only other Macs (%d)", comment: ""), foreignIds.count)) {
                    cleanupSelection = foreignIds
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.vertical, ClipinChrome.gap / 2)
    }

    private func cleanupRow(_ candidate: BackupCleanupService.Candidate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ClipinChrome.gap) {
            Toggle(isOn: Binding(
                get: { cleanupSelection.contains(candidate.id) },
                set: { isOn in
                    if isOn { cleanupSelection.insert(candidate.id) }
                    else { cleanupSelection.remove(candidate.id) }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: candidate.reason == .legacyJSON ? "doc.text" : "externaldrive.badge.icloud")
                .foregroundStyle(.tertiary)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(candidate.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(cleanupRowSubtitle(candidate))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
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
            cleanupSelection.removeAll()
            return
        }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        // 扫描失败 ≠ 无遗留：必须正面暴露错误避免误导用户。folderMissing 这种
        // "目录正常缺失"（用户改了路径还没同步、或 iCloud 离线）silently 清空候选即可。
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
        let liveIds = Set(cleanupCandidates.map(\.id))
        cleanupSelection.formIntersection(liveIds)
    }

    private func confirmCleanup() {
        guard activeOperation == nil else { return }
        let snapshot = cleanupCandidates.filter { cleanupSelection.contains($0.id) }
        guard !snapshot.isEmpty else { return }
        activeOperation = .cleanupBackupFolder
        showCleanupSheet = false
        Task { @MainActor in
            defer {
                activeOperation = nil
                cleanupSelection.removeAll()
            }
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
