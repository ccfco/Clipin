import SwiftUI

extension SettingsView {

    // MARK: - Transfer Tab

    var transferContent: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                actionRow(
                    "Export clipboard history",
                    description: "Create a JSON snapshot of your current history so it can be archived or moved elsewhere.",
                    buttonTitle: "Export JSON…",
                    busyTitle: "Exporting…",
                    isBusy: activeOperation == .exportArchive,
                    action: exportArchive
                )

                groupDivider

                actionRow(
                    "Import from an existing export",
                    description: "Bring items back from a previous JSON export. Existing items stay in place and duplicates are skipped.",
                    buttonTitle: "Import JSON…",
                    busyTitle: "Importing…",
                    isBusy: activeOperation == .importArchive,
                    action: importArchive
                )

                HStack(spacing: ClipinChrome.gap) {
                    Text("settings.archive.formatCaption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://github.com/ccfco/Clipin-archive-format")!) {
                        Text("settings.archive.openSpec")
                            .font(.caption)
                    }
                }
            }
        }
    }
}
