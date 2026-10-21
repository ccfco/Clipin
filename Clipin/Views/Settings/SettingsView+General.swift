import SwiftUI

extension SettingsView {

    // MARK: - General Tab
    //
    // 原生 grouped Form：每个 Section 自带卡片背景 + 行分隔线，按"用户做什么"分群：
    // 1. Startup & Shortcut：进入 app 的方式
    // 2. Launcher behavior：launcher 自身呈现策略
    // 3. Paste & Preview：粘贴/预览行为偏好
    // 4. Appearance：跨 app 视觉
    @ViewBuilder
    var generalContent: some View {
        startupSection
        launcherBehaviorSection
        filterOrderSection
        pasteAndPreviewSection
        appearanceSection
    }

    // MARK: - Startup & Shortcut

    private var startupSection: some View {
        Section("Startup & Shortcut") {
            LabeledContent {
                HStack(spacing: ClipinChrome.gap) {
                    ShortcutRecorder(
                        shortcut: Binding(
                            get: { settings.shortcut },
                            set: { settings.shortcut = $0 }
                        )
                    )
                    .frame(width: 180, height: 34)

                    Button("Reset") {
                        settings.shortcut = .default
                        showNotice(localized("Shortcut reset to %@.", settings.shortcut.displayString))
                    }
                    // 已是默认值时禁用——避免"按了没反应又弹 notice"的空动作
                    .disabled(settings.shortcut == .default)
                }
            } label: {
                Text("Global shortcut")
                Text("Click the field and press the new shortcut. At least one modifier key is required.")
                    .settingsCaption()
                if let note = settings.shortcutRegistrationNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            toggleRow(
                "Launch Clipin at login",
                "Clipin launches automatically after you sign in.",
                isOn: Binding(
                    get: { settings.launchAtLoginEnabled },
                    set: { settings.setLaunchAtLogin($0) }
                )
            )
            if let note = settings.launchAtLoginNote {
                Text(note)
                    .settingsCaption()
            }
        }
    }

    // MARK: - Launcher behavior

    private var launcherBehaviorSection: some View {
        Section("Launcher behavior") {
            Picker(selection: $settings.pinnedItemsPresentation) {
                ForEach(PinnedItemsPresentation.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                rowLabel(
                    "Favorites in the main list",
                    "Choose whether favorites mix into normal browsing, stay in a separate section, or only appear in the favorites view."
                )
            }

            Picker(selection: $settings.launcherDefaultView) {
                ForEach(LauncherDefaultView.allCases, id: \.self) { view in
                    Text(view.displayName).tag(view)
                }
            } label: {
                rowLabel(
                    "Launcher default view",
                    "Choose which browse view opens before you start typing. Search always scans the full library."
                )
            }

            toggleRow(
                "Remember panel position between sessions",
                "Reopen the panel where you last moved it, even after restarting Clipin.",
                isOn: $settings.rememberPanelPosition
            )
        }
    }

    // MARK: - Filter order

    /// Tab 循环 / 筛选菜单的类型顺序。All 固定第一、Pinned 是独立视图，均不参与重排；
    /// 默认把 Text 放最后（All 里文本最多，Text 筛选收益最低），用户可按自己的使用习惯调整。
    private var filterOrderSection: some View {
        Section {
            ForEach(Array(settings.filterCycleOrder.enumerated()), id: \.element) { index, mode in
                HStack(spacing: ClipinChrome.gap) {
                    Label(mode.displayName, systemImage: mode.systemImageName)
                    Spacer()
                    Button {
                        settings.moveFilter(mode, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel(Text("Move up"))
                    .help(NSLocalizedString("Move up", comment: ""))

                    Button {
                        settings.moveFilter(mode, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == settings.filterCycleOrder.count - 1)
                    .accessibilityLabel(Text("Move down"))
                    .help(NSLocalizedString("Move down", comment: ""))
                }
            }

            Button("Reset order") {
                settings.resetFilterCycleOrder()
            }
            .disabled(settings.filterCycleOrder == LauncherBrowseMode.defaultFilterCycleOrder)
        } header: {
            Text("Filter order")
        } footer: {
            Text("Order used by Tab cycling and the filter menu. All is always first; favorites have their own view (⌥F).")
        }
    }

    // MARK: - Paste & Preview

    private var pasteAndPreviewSection: some View {
        Section("Paste & Preview") {
            toggleRow(
                "Use Ctrl+V for images in terminal",
                "When the target app is a terminal and the clipboard item is an image, send Ctrl+V instead of Cmd+V. Useful for TUI apps like Claude Code that expect this shortcut for image paste.",
                isOn: $settings.useCtrlVInTerminalForImages
            )

            toggleRow(
                "Auto-fetch URL preview titles",
                "When you select a URL item, Clipin fetches the page title in the background. URLs with sensitive tokens or webhook-style paths are always skipped regardless of this setting.",
                isOn: $settings.urlPreviewAutoFetch
            )

            toggleRow(
                "Screenshot fallback for previews",
                "When a page declares no share image, render it in a headless browser to capture a screenshot — the only way to preview single-page apps (Feishu/DingTalk docs), local files, and intranet pages. Runs page JavaScript and loads third-party resources; cookies stay in memory and are never written to disk. Token and webhook URLs are always skipped.",
                isOn: $settings.urlPreviewScreenshot
            )
            .disabled(!settings.urlPreviewAutoFetch)
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker(selection: $settings.appearanceOverride) {
                ForEach(AppearanceOverride.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text("Theme")
            }
            .pickerStyle(.segmented)
            .frame(width: ClipinChrome.pickerWide)

            Picker(selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            } label: {
                rowLabel("Language", "Restart Clipin after changing the app language.")
            }
        }
    }
}
