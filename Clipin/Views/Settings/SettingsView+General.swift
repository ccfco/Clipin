import SwiftUI

extension SettingsView {

    // MARK: - General Tab

    var generalContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup {
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
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
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
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
}
