import SwiftUI

extension SettingsView {

    // MARK: - About Tab

    @ViewBuilder
    var aboutContent: some View {
        // App 身份卡：图标 + 名字 + 版本 + tagline，作为 About 自己的头部——
        // 本身就是它的 pane header，不再叠通用 paneHeader（避免「双头」冗余）。
        Section {
            identityHeaderRow(alignment: .top) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous))
            } content: {
                Text(appDisplayName)
                    .font(.system(size: 22, weight: .semibold))

                Text(currentVersionLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("A fast, keyboard-first clipboard companion for macOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Section("Updates") {
            Text("Clipin detects updates via GitHub Releases and installs them automatically.")
                .settingsCaption()

            toggleRow(
                "Automatically check for updates",
                "Check GitHub Releases in the background and surface a reminder when a new version is available.",
                isOn: updateAutoCheckBinding
            )

            actionRow(
                "Update status",
                description: updateStatusDescription,
                buttonTitle: "Check Now",
                action: { updateReminder.checkNow() }
            )

            if let latestRelease = updateReminder.latestRelease {
                LabeledContent {
                    HStack(spacing: ClipinChrome.gap) {
                        Button("View Release") { updateReminder.openReleasePage() }
                        Button("Install Update") { updateReminder.installUpdate() }
                            .buttonStyle(.borderedProminent)
                    }
                } label: {
                    rowLabel("Install latest version", "Install the latest version automatically, or open the GitHub release page.")
                }

                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    Text("Release notes")
                        .font(.system(size: 13, weight: .medium))
                    Text(latestRelease.notesPreview.isEmpty ? NSLocalizedString("No release notes provided.", comment: "") : latestRelease.notesPreview)
                        .settingsCaption()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        Section("Project") {
            LabeledContent {
                HStack(spacing: ClipinChrome.gap) {
                    Button("Source") { openExternalURL(Self.repositoryURL) }
                    Button("Releases") { updateReminder.openReleasesListPage() }
                    Button("Issues") { openExternalURL(Self.issuesURL) }
                }
            } label: {
                rowLabel("Project", "Browse the repository, all shipped releases, or report a bug—everything on GitHub.")
            }
        }
    }

    // MARK: - About Helpers

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Clipin"
    }

    private var currentVersionLine: String {
        "v\(updateReminder.currentVersion) (\(updateReminder.currentBuild))"
    }

    // Static stored properties are allowed in extensions; `let` stored properties are not.
    private static let repositoryURL = URL(string: "https://github.com/ccfco/Clipin")!
    private static let issuesURL = URL(string: "https://github.com/ccfco/Clipin/issues")!

    private var updateAutoCheckBinding: Binding<Bool> {
        Binding(
            get: { updateReminder.autoCheckEnabled },
            set: { updateReminder.setAutoCheckEnabled($0) }
        )
    }

    var updateStatusDescription: String {
        if updateReminder.isChecking {
            return NSLocalizedString("Checking for updates...", comment: "")
        }

        if let latestRelease = updateReminder.latestRelease {
            let publishedSuffix = latestRelease.publishedAt.map {
                String(
                    format: NSLocalizedString("Published %@.", comment: ""),
                    relativeString(from: $0, to: now)
                )
            } ?? ""
            return String(
                format: NSLocalizedString("Update available: %@", comment: ""),
                latestRelease.displayVersion
            ) + (publishedSuffix.isEmpty ? "" : " " + publishedSuffix)
        }

        if updateReminder.didLastCheckFail {
            return NSLocalizedString("Couldn't check for updates right now.", comment: "")
        }

        if let lastCheckedAt = updateReminder.lastCheckedAt {
            return String(
                format: NSLocalizedString("You're up to date. Last checked %@.", comment: ""),
                relativeString(from: lastCheckedAt, to: now)
            )
        }

        return NSLocalizedString("Checks GitHub Releases in the background and installs updates automatically.", comment: "")
    }
}
