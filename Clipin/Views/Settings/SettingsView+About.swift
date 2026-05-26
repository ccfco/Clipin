import SwiftUI

extension SettingsView {

    // MARK: - About Tab

    var aboutContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous))

                    VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                        Text(appDisplayName)
                            .font(.system(size: 22, weight: .semibold))

                        Text(currentVersionLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(ClipinInk.secondary)

                        Text("A fast, keyboard-first clipboard companion for macOS.")
                            .font(.system(size: 12))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }

            contentGroup {
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                    VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                        Text("Updates")
                            .font(.system(size: 13, weight: .medium))

                        Text("Clipin checks GitHub Releases and lets you download the newest build manually.")
                            .font(.system(size: 11))
                            .foregroundStyle(ClipinInk.secondary)
                    }

                    toggleSettingRow(
                        "Automatically check for updates",
                        description: "Check GitHub Releases in the background and surface a reminder when a new version is available.",
                        isOn: updateAutoCheckBinding
                    )

                    groupDivider

                    actionRow(
                        "Update status",
                        description: updateStatusDescription,
                        buttonTitle: "Check Now",
                        action: { updateReminder.checkNow() }
                    )

                    if let latestRelease = updateReminder.latestRelease {
                        groupDivider

                        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                            Text("Release notes")
                                .font(.system(size: 13, weight: .medium))

                            Text(latestRelease.notesPreview.isEmpty ? NSLocalizedString("No release notes provided.", comment: "") : latestRelease.notesPreview)
                                .font(.system(size: 11))
                                .foregroundStyle(ClipinInk.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        groupDivider

                        HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
                            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                                Text("Get the latest build")
                                    .font(.system(size: 13, weight: .medium))

                                Text("Open the GitHub release page, or jump straight to the latest installer asset.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ClipinInk.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: ClipinChrome.gap) {
                                Button("View Release") {
                                    updateReminder.openReleasePage()
                                }
                                .buttonStyle(.bordered)

                                Button("Download Latest") {
                                    updateReminder.downloadLatestRelease()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }

            contentGroup {
                // 三个 GitHub 链接合成一个 horizontal 按钮组——它们都是"打开 GitHub 子页"
                // 同类动作，不需要各占一整行 actionRow，节省 ~80px 垂直空间且分类更清晰。
                HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
                    VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                        Text("Project")
                            .font(.system(size: 13, weight: .medium))

                        Text("Browse the repository, all shipped releases, or report a bug—everything on GitHub.")
                            .font(.system(size: 11))
                            .foregroundStyle(ClipinInk.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: ClipinChrome.gap) {
                        Button("Source") { openExternalURL(Self.repositoryURL) }
                            .buttonStyle(.bordered)
                        Button("Releases") { updateReminder.openReleasesListPage() }
                            .buttonStyle(.bordered)
                        Button("Issues") { openExternalURL(Self.issuesURL) }
                            .buttonStyle(.bordered)
                    }
                }
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

        return NSLocalizedString("Checks GitHub Releases in the background and lets you download the latest version manually.", comment: "")
    }
}
