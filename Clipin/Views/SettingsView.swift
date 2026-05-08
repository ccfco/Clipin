import SwiftUI
import AppKit

// MARK: - SettingsTab

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, privacy, retention, transfer, autoBackup, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:      return "General"
        case .privacy:      return "Privacy"
        case .retention:    return "Retention"
        case .transfer:     return "Transfer"
        case .autoBackup:   return "Auto Backup"
        case .about:        return "About"
        }
    }
    var icon: String {
        switch self {
        case .general:      return "gear"
        case .privacy:      return "hand.raised"
        case .retention:    return "clock.arrow.circlepath"
        case .transfer:     return "arrow.left.arrow.right.circle"
        case .autoBackup:   return "icloud.and.arrow.up"
        case .about:        return "info.circle"
        }
    }

    var summary: LocalizedStringKey {
        switch self {
        case .general:
            return "Fine-tune keyboard behavior, launch defaults, and how Clipin looks."
        case .privacy:
            return "Control which clipboard writes are ignored so sensitive or noisy content stays out."
        case .retention:
            return "Set how long history stays around and when unpinned items should be trimmed."
        case .transfer:
            return "Move clipboard history in or out of Clipin without losing your current library."
        case .autoBackup:
            return "Keep an automatic JSON backup on disk so history can be restored if needed."
        case .about:
            return "App version, updates, project links, and release notes."
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published private(set) var selectedTab: SettingsTab?

    init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }

    func select(_ tab: SettingsTab?) {
        selectedTab = tab
    }

    func ensureSelection(_ fallback: SettingsTab = .general) {
        if selectedTab == nil { selectedTab = fallback }
    }

    func selectNext() {
        let all = SettingsTab.allCases
        guard let current = selectedTab, let idx = all.firstIndex(of: current) else { return }
        selectedTab = all[min(idx + 1, all.count - 1)]
    }

    func selectPrev() {
        let all = SettingsTab.allCases
        guard let current = selectedTab, let idx = all.firstIndex(of: current) else { return }
        selectedTab = all[max(idx - 1, 0)]
    }
}

// MARK: - SettingsView

private struct SettingsNotice {
    let text: String
    let isError: Bool
}


struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updateReminder: UpdateReminderService
    @ObservedObject var autoBackup: AutoBackupService
    @ObservedObject var navigation: SettingsNavigationModel
    let core: ClipinCore

    @Environment(\.colorScheme) private var colorScheme
    @State private var notice: SettingsNotice?
    @State private var dismissTask: Task<Void, Never>?
    @State private var now: Date = .now
    @State private var tickTimer: Timer?
    @State private var hoveredTab: SettingsTab?

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Clipin"
    }

    private var currentVersionLine: String {
        "v\(updateReminder.currentVersion) (\(updateReminder.currentBuild))"
    }

    private let repositoryURL = URL(string: "https://github.com/ccfco/Clipin")!
    private let issuesURL = URL(string: "https://github.com/ccfco/Clipin/issues")!
    private let contentStackSpacing: CGFloat = 18

    private var updateAutoCheckBinding: Binding<Bool> {
        Binding(
            get: { updateReminder.autoCheckEnabled },
            set: { updateReminder.setAutoCheckEnabled($0) }
        )
    }

    private var updateStatusDescription: String {
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

    var body: some View {
        ZStack {
            windowBackdrop
            HStack(spacing: ClipinChrome.shellGap) {
                sidebar
                contentArea
                    .animation(ClipinMotion.panel, value: navigation.selectedTab)
            }
            .padding(ClipinChrome.shellGap)
        }
        .frame(width: 748, height: 620)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let notice {
                noticeView(notice)
                    .padding(.horizontal, 20)
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
            notice = nil
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(tab)
                }
            }
            .padding(.vertical, 6)
        }
        .background(
            ClipinSurfaceBackground(
                role: .sidebar,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = navigation.selectedTab == tab
        let isHovered = hoveredTab == tab

        return HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSelected ? hierarchy.selection.ink : hierarchy.support.subduedInk)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? hierarchy.selection.badgeFill : glass.keycapTint)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(
                                    isSelected ? hierarchy.selection.stroke.opacity(0.72) : glass.hoverStroke.opacity(0.82),
                                    lineWidth: 0.5
                                )
                        )
                )

            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? hierarchy.selection.ink : hierarchy.support.subduedInk)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ClipinSelectableRowBackground(
                isSelected: isSelected,
                isHovered: isHovered,
                selectionFill: hierarchy.selection.fill,
                selectionStroke: hierarchy.selection.stroke,
                hoverFill: glass.hoverFill,
                hoverStroke: glass.hoverStroke
            )
        )
        .padding(.horizontal, ClipinChrome.listRowOuterInset)
        .contentShape(Rectangle())
        .onTapGesture { navigation.select(tab) }
        .onHover { hovered in hoveredTab = hovered ? tab : nil }
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ClipinChrome.detailGroupSpacing) {
                if let tab = navigation.selectedTab {
                    detailHeader(for: tab)

                    switch tab {
                    case .general:      generalContent
                    case .privacy:      privacyContent
                    case .retention:    retentionContent
                    case .transfer:     transferContent
                    case .autoBackup:   autoBackupContent
                    case .about:        aboutContent
                    }
                } else {
                    settingsSelectionPlaceholder
                }
            }
            .id(navigation.selectedTab?.rawValue)
            .padding(ClipinChrome.detailContentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            ClipinSurfaceBackground(
                role: .column,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Global shortcut")
                            .font(.system(size: 13, weight: .medium))

                        HStack(spacing: 10) {
                            ShortcutRecorder(
                                shortcut: Binding(
                                    get: { settings.shortcut },
                                    set: { settings.shortcut = $0 }
                                ),
                                glass: glass
                            )
                            .frame(width: 180, height: 34)

                            Button("Reset") {
                                settings.shortcut = .default
                                showNotice(localized("Shortcut reset to %@.", settings.shortcut.displayString))
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Click the field and press the new shortcut. At least one modifier key is required.")
                            .font(.system(size: 11))
                            .foregroundStyle(hierarchy.support.subduedInk)
                    }

                    groupDivider

                    toggleSettingRow(
                        "Launch Clipin at login",
                        description: "Clipin launches automatically after you sign in.",
                        note: settings.launchAtLoginNote,
                        isOn: Binding(
                            get: { settings.launchAtLoginEnabled },
                            set: { settings.setLaunchAtLogin($0) }
                        )
                    )

                    groupDivider

                    settingFieldRow(
                        "Pinned items in the main list",
                        description: "Choose whether pinned items mix into normal browsing, stay in a separate section, or only appear in the pinned view."
                    ) {
                        Picker("", selection: $settings.pinnedItemsPresentation) {
                            ForEach(PinnedItemsPresentation.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    groupDivider

                    settingFieldRow(
                        "Launcher default view",
                        description: "Choose which browse view opens before you start typing. Search always scans the full library."
                    ) {
                        Picker("", selection: $settings.launcherDefaultView) {
                            ForEach(LauncherDefaultView.allCases, id: \.self) { view in
                                Text(view.displayName).tag(view)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    groupDivider

                    toggleSettingRow(
                        "Remember panel position between sessions",
                        description: "Reopen the panel where you last moved it, even after restarting Clipin.",
                        isOn: $settings.rememberPanelPosition
                    )

                    groupDivider

                    toggleSettingRow(
                        "Use Ctrl+V for images in terminal",
                        description: "When the target app is a terminal and the clipboard item is an image, send Ctrl+V instead of Cmd+V. Useful for TUI apps like Claude Code that expect this shortcut for image paste.",
                        isOn: $settings.useCtrlVInTerminalForImages
                    )
                }
            }

            contentGroup {
                VStack(alignment: .leading, spacing: 18) {
                    settingFieldRow("Appearance") {
                        Picker("", selection: $settings.appearanceOverride) {
                            ForEach(AppearanceOverride.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    groupDivider

                    settingFieldRow("Theme", description: "Adjust the panel tint while keeping native materials and shared chrome.") {
                        Picker("", selection: $settings.visualTheme) {
                            ForEach(VisualTheme.allCases, id: \.self) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    groupDivider

                    settingFieldRow("Language", description: "Restart Clipin after changing the app language.") {
                        Picker("", selection: $settings.appLanguage) {
                            ForEach(AppLanguage.allCases, id: \.self) { lang in
                                Text(lang.displayName).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 170)
                    }
                }
            }

        }
    }

    // MARK: - Privacy

    private var privacyContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup(role: .control, padding: 14) {
                infoCallout(
                    icon: "checkmark.shield.fill",
                    tint: .green,
                    title: "Sensitive content is always excluded",
                    message: "When apps like 1Password or Bitwarden mark content as sensitive, Clipin never records it. This cannot be turned off."
                )
            }

            contentGroup {
                toggleSettingRow(
                    "Filter out drag-and-drop and app-generated clipboard writes",
                    description: "Skip clipboard writes that were not triggered by an explicit copy action so noisy transient items do not enter history.",
                    isOn: Binding(
                        get: { settings.skipTransientContent },
                        set: { settings.skipTransientContent = $0 }
                    )
                )
            }
        }
    }

    // MARK: - Retention

    private static let retentionOptions: [(label: String, days: Int)] = [
        ("7 days", 7), ("30 days", 30), ("90 days", 90),
        ("1 year", 365), ("3 years", 1095), ("Forever", 0),
    ]
    private static let maxItemsOptions: [(label: String, count: Int)] = [
        ("500", 500), ("1K", 1_000), ("5K", 5_000),
        ("10K", 10_000), ("50K", 50_000), ("Unlimited", 0),
    ]

    private var normalizedRetentionDays: Binding<Int> {
        Binding(
            get: {
                let v = settings.retentionDays
                return Self.retentionOptions.map(\.days).contains(v) ? v
                    : Self.retentionOptions.map(\.days).min(by: { abs($0 - v) < abs($1 - v) }) ?? 30
            },
            set: { settings.retentionDays = $0 }
        )
    }
    private var normalizedMaxItems: Binding<Int> {
        Binding(
            get: {
                let v = settings.maxHistoryItems
                return Self.maxItemsOptions.map(\.count).contains(v) ? v
                    : Self.maxItemsOptions.map(\.count).min(by: { abs($0 - v) < abs($1 - v) }) ?? 500
            },
            set: { settings.maxHistoryItems = $0 }
        )
    }

    private var retentionContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                VStack(alignment: .leading, spacing: 18) {
                    settingFieldRow("Keep unpinned history for", description: "Pinned items are always preserved.") {
                        Picker("", selection: normalizedRetentionDays) {
                            ForEach(Self.retentionOptions, id: \.days) { option in
                                Text(LocalizedStringKey(option.label)).tag(option.days)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    groupDivider

                    settingFieldRow("Max unpinned items", description: "Oldest unpinned items are trimmed first when the limit is reached.") {
                        Picker("", selection: normalizedMaxItems) {
                            ForEach(Self.maxItemsOptions, id: \.count) { option in
                                Text(LocalizedStringKey(option.label)).tag(option.count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)
                    }

                    groupDivider

                    actionRow(
                        "Run Cleanup Now",
                        description: "Apply the current retention rules immediately and remove outdated unpinned items.",
                        buttonTitle: "Run Cleanup Now",
                        action: runCleanup
                    )
                }
            }
        }
    }

    // MARK: - Transfer

    private var transferContent: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: 18) {
                actionRow(
                    "Export clipboard history",
                    description: "Create a JSON snapshot of your current history so it can be archived or moved elsewhere.",
                    buttonTitle: "Export JSON…",
                    action: exportArchive
                )

                groupDivider

                actionRow(
                    "Import from an existing export",
                    description: "Bring items back from a previous JSON export. Existing items stay in place and duplicates are skipped.",
                    buttonTitle: "Import JSON…",
                    action: importArchive
                )
            }
        }
    }

    // MARK: - Auto Backup

    private var autoBackupContent: some View {
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
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Backup folder")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                settings.autoBackupFolderPath.map(abbreviatedPath)
                                    ?? "Choose a destination folder for clipin-backup.json."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(hierarchy.support.subduedInk)
                            .lineLimit(2)
                            .truncationMode(.middle)

                            HStack(spacing: 8) {
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

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Backup status")
                                .font(.system(size: 13, weight: .medium))

                            contentGroup(role: .control, padding: 14) {
                                HStack(spacing: 10) {
                                    if let error = autoBackup.lastBackupError {
                                        Circle().fill(Color.red).frame(width: 7, height: 7)
                                        Text(localized("Backup failed: %@", error))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.red)
                                    } else if let date = autoBackup.lastBackupAt {
                                        Circle().fill(Color.green).frame(width: 7, height: 7)
                                        Text(localized("Last backup: %@", relativeString(from: date, to: now)))
                                            .font(.system(size: 11))
                                            .foregroundStyle(hierarchy.support.subduedInk)
                                    } else {
                                        Circle().fill(Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                                        Text("No backup yet")
                                            .font(.system(size: 11))
                                            .foregroundStyle(hierarchy.support.hintInk)
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
            }
        }
    }

    // MARK: - About

    private var aboutContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                HStack(alignment: .top, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(appDisplayName)
                            .font(.system(size: 22, weight: .semibold))

                        Text(currentVersionLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(hierarchy.support.subduedInk)

                        Text("A fast, keyboard-first clipboard companion for macOS.")
                            .font(.system(size: 12))
                            .foregroundStyle(hierarchy.support.subduedInk)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                }
            }

            contentGroup {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Updates")
                            .font(.system(size: 13, weight: .medium))

                        Text("Clipin checks GitHub Releases and lets you download the newest build manually.")
                            .font(.system(size: 11))
                            .foregroundStyle(hierarchy.support.subduedInk)
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

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Release notes")
                                .font(.system(size: 13, weight: .medium))

                            Text(latestRelease.notesPreview.isEmpty ? NSLocalizedString("No release notes provided.", comment: "") : latestRelease.notesPreview)
                                .font(.system(size: 11))
                                .foregroundStyle(hierarchy.support.subduedInk)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        groupDivider

                        HStack(alignment: .top, spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Get the latest build")
                                    .font(.system(size: 13, weight: .medium))

                                Text("Open the GitHub release page, or jump straight to the latest installer asset.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(hierarchy.support.subduedInk)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            HStack(spacing: 8) {
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
                VStack(alignment: .leading, spacing: 18) {
                    Text("Project")
                        .font(.system(size: 13, weight: .medium))

                    actionRow(
                        "Source code",
                        description: "Browse the repository, implementation details, and development history on GitHub.",
                        buttonTitle: "Open GitHub",
                        action: { openExternalURL(repositoryURL) }
                    )

                    groupDivider

                    actionRow(
                        "Release history",
                        description: "Browse all shipped builds and release notes on GitHub.",
                        buttonTitle: "Open Releases",
                        action: { updateReminder.openReleasesListPage() }
                    )

                    groupDivider

                    actionRow(
                        "Report an issue",
                        description: "Open GitHub Issues to report bugs, request features, or continue a discussion.",
                        buttonTitle: "Open Issues",
                        action: { openExternalURL(issuesURL) }
                    )
                }
            }
        }
    }

    // MARK: - Transfer

    private func detailHeader(for tab: SettingsTab) -> some View {
        contentGroup(role: .contentStage, padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                ClipinSymbolOrb(systemImage: tab.icon, glass: glass, hierarchy: hierarchy, size: 58, iconSize: 20)

                ClipinSectionIntro(
                    title: tab.title,
                    subtitle: tab.summary,
                    hierarchy: hierarchy,
                    eyebrow: "Preferences",
                    titleFontSize: 21
                )

                Spacer(minLength: 0)
            }
        }
    }

    private var windowBackdrop: some View {
        ClipinShellBackground(glass: glass, cornerRadius: ClipinChrome.shellCornerRadius)
            .ignoresSafeArea()
    }

    private var groupDivider: some View {
        Rectangle()
            .fill(hierarchy.support.hintInk.opacity(colorScheme == .dark ? 0.16 : 0.12))
            .frame(height: 1)
    }

    private var settingsSelectionPlaceholder: some View {
        contentGroup(role: .contentStage, padding: 18) {
            ClipinSectionIntro(
                title: "Choose a section",
                subtitle: "Select a section from the sidebar to edit Clipin preferences.",
                hierarchy: hierarchy,
                eyebrow: "Preferences",
                titleFontSize: 18,
                subtitleFontSize: 12
            )
        }
    }

    private func settingFieldRow<Control: View>(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: description == nil ? .firstTextBaseline : .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(hierarchy.support.subduedInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
    }

    private func toggleSettingRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        note: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(hierarchy.support.subduedInk)

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(hierarchy.support.subduedInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(
            title: title,
            descriptionView: Text(description),
            buttonTitle: buttonTitle,
            action: action
        )
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        description: String,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(
            title: title,
            descriptionView: Text(description),
            buttonTitle: buttonTitle,
            action: action
        )
    }

    private func actionRow<Description: View>(
        title: LocalizedStringKey,
        descriptionView: Description,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                descriptionView
                    .font(.system(size: 11))
                    .foregroundStyle(hierarchy.support.subduedInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
        }
    }

    private func infoCallout(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .medium))

                Text(LocalizedStringKey(message))
                    .font(.system(size: 11))
                    .foregroundStyle(hierarchy.support.subduedInk)
            }
        }
    }

    private func contentGroup<Content: View>(
        role: ClipinSurfaceRole = .grouped,
        padding: CGFloat = 18,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                ClipinSurfaceBackground(
                    role: role,
                    cornerRadius: ClipinChrome.cardCornerRadius,
                    glass: glass
                )
            )
    }

    private func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func noticeView(_ notice: SettingsNotice) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(notice.isError ? Color.red : glass.emphasisInk)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(hierarchy.support.subduedInk)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ClipinSurfaceBackground(
                role: .control,
                cornerRadius: ClipinChrome.searchCornerRadius,
                glass: glass
            )
        )
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

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
    }

    // MARK: - Actions

    private func runCleanup() {
        Task {
            do {
                let result = try await CleanupService(core: core, settings: settings).runNow()
                NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
                if result.totalRemoved == 0 {
                    showNotice(NSLocalizedString("Nothing needed cleanup. Your history already fits the current policy.", comment: ""))
                } else {
                    showNotice(
                        localized(
                            "Removed %d items (%d by age, %d by count).",
                            result.totalRemoved,
                            result.removedByAge,
                            result.removedByCount
                        )
                    )
                }
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    private func exportArchive() {
        Task {
            do {
                let result = try await ArchiveService.exportArchive(core: core)
                showNotice(
                    localized(
                        "Exported %d items to %@.",
                        result.exportedCount,
                        result.url.lastPathComponent
                    ) + skippedSuffix(result.skippedCount)
                )
            } catch ArchiveError.cancelled {
                return
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    private func importArchive() {
        Task {
            do {
                let result = try await ArchiveService.importArchive(core: core)
                let cleanup = try await CleanupService(core: core, settings: settings).runNow()
                NotificationCenter.default.post(name: .clipHistoryDidChange, object: nil)
                let cleanupSuffix = cleanup.totalRemoved > 0
                    ? " " + localized("Cleanup removed %d older items.", cleanup.totalRemoved)
                    : ""
                showNotice(
                    localized(
                        "Imported %d items from %@.",
                        result.importedCount,
                        result.url.lastPathComponent
                    ) + skippedSuffix(result.skippedCount) + cleanupSuffix
                )
            } catch ArchiveError.cancelled {
                return
            } catch {
                showNotice(error.localizedDescription, isError: true)
            }
        }
    }

    private func skippedSuffix(_ skippedCount: Int) -> String {
        skippedCount > 0
            ? " " + localized("Skipped %d items with missing image data.", skippedCount)
            : ""
    }

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

    private static let _relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private func relativeString(from date: Date, to now: Date) -> String {
        Self._relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
