import SwiftUI

extension SettingsView {

    // MARK: - General Tab

    /// 拆 4 个 group——按"用户做什么"分群，避免 7 个开关挤一个面板看不出层级：
    /// 1. Startup & Shortcut：进入 app 的方式
    /// 2. Launcher behavior：launcher 自身呈现策略
    /// 3. Paste & Preview：粘贴/预览行为偏好
    /// 4. Appearance：跨 app 视觉
    var generalContent: some View {
        VStack(spacing: contentStackSpacing) {
            startupGroup
            launcherBehaviorGroup
            pasteAndPreviewGroup
            appearanceGroup
        }
    }

    // MARK: - Startup & Shortcut

    private var startupGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                groupHeader("Startup & Shortcut")

                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    Text("Global shortcut")
                        .font(.system(size: 13, weight: .medium))

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
                        .buttonStyle(.bordered)
                        // 已是默认值时禁用——避免"按了没反应又弹 notice"的空动作
                        .disabled(settings.shortcut == .default)
                    }

                    Text("Click the field and press the new shortcut. At least one modifier key is required.")
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.secondary)

                    if let note = settings.shortcutRegistrationNote {
                        Label(note, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            }
        }
    }

    // MARK: - Launcher behavior

    private var launcherBehaviorGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                groupHeader("Launcher behavior")

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
                    .frame(width: ClipinChrome.pickerWide)
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
                    .frame(width: ClipinChrome.pickerWide)
                }

                groupDivider

                toggleSettingRow(
                    "Remember panel position between sessions",
                    description: "Reopen the panel where you last moved it, even after restarting Clipin.",
                    isOn: $settings.rememberPanelPosition
                )
            }
        }
    }

    // MARK: - Paste & Preview

    private var pasteAndPreviewGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                groupHeader("Paste & Preview")

                toggleSettingRow(
                    "Use Ctrl+V for images in terminal",
                    description: "When the target app is a terminal and the clipboard item is an image, send Ctrl+V instead of Cmd+V. Useful for TUI apps like Claude Code that expect this shortcut for image paste.",
                    isOn: $settings.useCtrlVInTerminalForImages
                )

                groupDivider

                toggleSettingRow(
                    "Auto-fetch URL preview titles",
                    description: "When you select a URL item, Clipin fetches the page title in the background. URLs with sensitive tokens or webhook-style paths are always skipped regardless of this setting.",
                    isOn: $settings.urlPreviewAutoFetch
                )

                groupDivider

                toggleSettingRow(
                    "Screenshot fallback for previews",
                    description: "When a page declares no share image, render it in a headless browser to capture a screenshot — the only way to preview single-page apps (Feishu/DingTalk docs), local files, and intranet pages. Runs page JavaScript and loads third-party resources; cookies stay in memory and are never written to disk. Token and webhook URLs are always skipped.",
                    isOn: $settings.urlPreviewScreenshot
                )
                .disabled(!settings.urlPreviewAutoFetch)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceGroup: some View {
        contentGroup {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                groupHeader("Appearance")

                settingFieldRow("Theme") {
                    Picker("", selection: $settings.appearanceOverride) {
                        ForEach(AppearanceOverride.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: ClipinChrome.pickerWide)
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
                    .frame(width: ClipinChrome.pickerMedium)
                }
            }
        }
    }
}
