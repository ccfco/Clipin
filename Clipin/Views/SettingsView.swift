import SwiftUI
import AppKit

// MARK: - SettingsTab

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, privacy, retention, transfer, autoBackup
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general:   return "General"
        case .privacy:   return "Privacy"
        case .retention: return "Retention"
        case .transfer:  return "Transfer"
        case .autoBackup: return "Auto Backup"
        }
    }
    var icon: String {
        switch self {
        case .general:   return "gear"
        case .privacy:   return "hand.raised"
        case .retention: return "clock.arrow.circlepath"
        case .transfer:  return "arrow.left.arrow.right.circle"
        case .autoBackup: return "icloud.and.arrow.up"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published private(set) var selectedTab: SettingsTab

    init(selectedTab: SettingsTab = .general) {
        self.selectedTab = selectedTab
    }

    func select(_ tab: SettingsTab) {
        selectedTab = tab
    }
}

// MARK: - SettingsView

private struct SettingsNotice {
    let text: String
    let isError: Bool
}

private struct SettingsSidebarChromeBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.postsFrameChangedNotifications = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let tableView = context.coordinator.findTableView(from: nsView) else { return }
            if context.coordinator.tableView !== tableView {
                context.coordinator.tableView = tableView
            }
            context.coordinator.configure(tableView: tableView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var tableView: NSTableView?

        func findTableView(from view: NSView) -> NSTableView? {
            var current: NSView? = view
            while let node = current {
                if let tableView = node as? NSTableView {
                    return tableView
                }
                if let tableView = findTableView(in: node) {
                    return tableView
                }
                current = node.superview
            }
            return nil
        }

        private func findTableView(in root: NSView) -> NSTableView? {
            for child in root.subviews {
                if let tableView = child as? NSTableView {
                    return tableView
                }
                if let tableView = findTableView(in: child) {
                    return tableView
                }
            }
            return nil
        }

        func configure(tableView: NSTableView) {
            tableView.selectionHighlightStyle = .none
            tableView.backgroundColor = .clear
            tableView.intercellSpacing = NSSize(width: 0, height: 6)
            tableView.enclosingScrollView?.drawsBackground = false
            tableView.enclosingScrollView?.backgroundColor = .clear
            tableView.enclosingScrollView?.focusRingType = .none
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
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

    private var selectedSidebarTab: Binding<SettingsTab?> {
        Binding(
            get: { navigation.selectedTab },
            set: { tab in
                navigation.select(tab ?? navigation.selectedTab)
            }
        )
    }

    var body: some View {
        ZStack {
            windowBackdrop
            HStack(spacing: 14) {
                sidebar
                contentArea
                    .animation(ClipinMotion.panel, value: navigation.selectedTab)
            }
            .padding(14)
        }
        .frame(width: 680, height: 600)
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
        List(SettingsTab.allCases, selection: selectedSidebarTab) { tab in
            settingsSidebarRow(tab)
                .tag(tab)
                .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.sidebar)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .background(SettingsSidebarChromeBridge())
        .background(
            ClipinSurfaceBackground(
                role: .sidebar,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func settingsSidebarRow(_ tab: SettingsTab) -> some View {
        let isSelected = navigation.selectedTab == tab
        let isHovered = hoveredTab == tab

        return HStack(spacing: 10) {
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? hierarchy.selection.ink : Color.secondary)

            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? hierarchy.selection.ink : Color.primary.opacity(0.88))

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
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
        .contentShape(Rectangle())
        .onHover { hovered in
            hoveredTab = hovered ? tab : nil
        }
        .animation(ClipinMotion.selection, value: isSelected)
        .animation(ClipinMotion.feedback, value: isHovered)
    }

    // MARK: - Content Area

    private var contentArea: some View {
        let tab = navigation.selectedTab
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(tab.title)
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 2)

                switch tab {
                case .general:    generalContent
                case .privacy:    privacyContent
                case .retention:  retentionContent
                case .transfer:   transferContent
                case .autoBackup: autoBackupContent
                }
            }
            .id(tab)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            ClipinSurfaceBackground(
                role: .detail,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(spacing: 14) {
            contentGroup {
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
                            showNotice("Shortcut reset to \(settings.shortcut.displayString).")
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Click the field and press the new shortcut. At least one modifier key is required.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            contentGroup {
                VStack(spacing: 18) {
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

                    VStack(alignment: .leading, spacing: 4) {
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
                            .frame(width: 200)
                        }
                        Text("Changes the panel tint while keeping native materials.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Language")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Picker("", selection: $settings.appLanguage) {
                                ForEach(AppLanguage.allCases, id: \.self) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 160)
                        }
                        Text("Restart Clipin to apply the language change.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            contentGroup {
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

            contentGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Remember panel position between sessions", isOn: $settings.rememberPanelPosition)
                        .toggleStyle(.switch)
                    Text("When enabled, the panel reopens at the last position you moved it to, even after restarting Clipin.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Privacy

    private var privacyContent: some View {
        VStack(spacing: 14) {
            contentGroup {
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
            }

            contentGroup {
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
        VStack(spacing: 14) {
            contentGroup {
                VStack(spacing: 16) {
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
                }
            }

            contentGroup {
                Button("Run Cleanup Now") { runCleanup() }
                    .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Transfer

    private var transferContent: some View {
        contentGroup {
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
                    Button("Export JSON…") { exportArchive() }
                        .buttonStyle(.bordered)
                    Button("Import JSON…") { importArchive() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Auto Backup

    private var autoBackupContent: some View {
        VStack(spacing: 14) {
            contentGroup {
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
                }
            }

            if settings.autoBackupEnabled {
                contentGroup {
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
                }

                contentGroup {
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
                }

                contentGroup {
                    HStack(spacing: 8) {
                        if let error = autoBackup.lastBackupError {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("Backup failed: \(error)")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        } else if let date = autoBackup.lastBackupAt {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
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

    // MARK: - Window backdrop & helpers

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
            .overlay(
                LinearGradient(
                    colors: [glass.shellHighlight.opacity(colorScheme == .dark ? 0.18 : 0.42), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .ignoresSafeArea()
    }

    private func contentGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                ClipinSurfaceBackground(
                    role: .grouped,
                    cornerRadius: ClipinChrome.cardCornerRadius,
                    glass: glass
                )
            )
    }

    private func noticeView(_ notice: SettingsNotice) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(notice.isError ? Color.red : glass.emphasisInk)
                .frame(width: 8, height: 8)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.78))
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

    // MARK: - Actions

    private func runCleanup() {
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
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
