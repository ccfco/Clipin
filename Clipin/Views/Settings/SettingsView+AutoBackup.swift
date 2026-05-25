import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - Auto Backup Tab

    var autoBackupContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                toggleSettingRow(
                    "Enable auto backup",
                    description: "Export history as clipin-backup.json on a schedule. Store it in iCloud Drive, Dropbox, or any folder you trust.",
                    isOn: $settings.autoBackupEnabled
                )
            }

            if settings.autoBackupEnabled {
                contentGroup {
                    VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                            Text("Backup folder")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                settings.autoBackupFolderPath.map(abbreviatedPath)
                                    ?? "Choose a destination folder for clipin-backup.json."
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
                            }
                        }

                        groupDivider

                        settingFieldRow("Frequency", description: "Choose how often Clipin writes a fresh backup file.") {
                            Picker("", selection: $settings.autoBackupInterval) {
                                ForEach(AutoBackupInterval.allCases, id: \.self) { interval in
                                    Text(interval.displayName).tag(interval)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }

                        groupDivider

                        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                            Text("Backup status")
                                .font(.system(size: 13, weight: .medium))

                            contentGroup(padding: ClipinChrome.groupGap) {
                                HStack(spacing: ClipinChrome.gap) {
                                    if let error = autoBackup.lastBackupError {
                                        Circle().fill(Color.red).frame(width: 7, height: 7)
                                        Text(localized("Backup failed: %@", error))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                    } else if let date = autoBackup.lastBackupAt {
                                        Circle().fill(Color.green).frame(width: 7, height: 7)
                                        Text(localized("Last backup: %@", relativeString(from: date, to: now)))
                                            .font(.system(size: 11))
                                            .foregroundStyle(ClipinInk.secondary)
                                    } else {
                                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                        Text("No backup yet")
                                            .font(.system(size: 11))
                                            .foregroundStyle(ClipinInk.tertiary)
                                    }

                                    Spacer()

                                    if settings.autoBackupFolderPath != nil {
                                        Button {
                                            autoBackup.backupNow()
                                        } label: {
                                            progressButtonLabel(
                                                title: autoBackup.isBackingUp ? "Backing Up…" : "Backup Now",
                                                isBusy: autoBackup.isBackingUp
                                            )
                                        }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(autoBackup.isBackingUp)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Folder Helpers

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Choose Backup Folder", comment: "")
        panel.message = NSLocalizedString("Choose a folder for the clipin-backup.json file.", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.autoBackupFolderPath = url.path
    }

    private func useICloudDrive() {
        let icloudURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Clipin")
        do {
            try FileManager.default.createDirectory(at: icloudURL, withIntermediateDirectories: true)
            settings.autoBackupFolderPath = icloudURL.path
        } catch {
            showNotice(localized("Cannot create iCloud Drive folder: %@", error.localizedDescription), isError: true)
        }
    }
}
