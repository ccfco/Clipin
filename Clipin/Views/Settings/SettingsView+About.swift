import SwiftUI

extension SettingsView {

    // MARK: - About Pane

    /// About 是「身份页」不是「设置表单」——按 Raycast / 原生 macOS About 的做法：
    /// 居中 hero（大图标 + 名字 + 版本 + tagline）+ 下方 grouped 卡片（Updates / Project）。
    /// hero 曾是浮在 Form 之外、无背景的独立 VStack；改成 Form 内首个 Section 是为了拿到滚动
    /// 边缘玻璃模糊（macOS 26 scroll edge effect）——排除法验证过：hero 不在 Form 的滚动区域内
    /// 时，标题栏下会露出一条静态分隔线，且怎么关都关不掉（titlebarSeparatorStyle=.none 无效，
    /// 另套一层禁用滚动的 ScrollView 仍然无效，还会带出嵌套滚动 bug——两种 hack 都试过，均失败）；
    /// 唯一可靠的修法是让 hero 本身处于 Form 的同一滚动区域内，代价是随 Section 带一张浅灰卡片
    /// 背景（Niche「关于」页同款处理）。
    var aboutPane: some View {
        Form {
            Section {
                aboutHero
            }
            aboutContent
        }
        .formStyle(.grouped)
    }

    /// 居中身份 hero：app 图标 + 名字 + 版本 + 一句 tagline，Section 内居中排布。
    private var aboutHero: some View {
        VStack(spacing: ClipinChrome.gap) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)

            Text(appDisplayName)
                .font(.system(size: 26, weight: .bold))

            Text(currentVersionLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("A fast, keyboard-first clipboard companion for macOS.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, ClipinChrome.groupGap * 2)
        .padding(.bottom, ClipinChrome.groupGap)
        .padding(.horizontal, ClipinChrome.groupGap)
    }

    // MARK: - About Form Sections

    @ViewBuilder
    var aboutContent: some View {
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
