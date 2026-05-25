import SwiftUI

extension SettingsView {

    // MARK: - Detail Header

    func detailHeader(for tab: SettingsTab) -> some View {
        contentGroup(padding: ClipinChrome.groupGap) {
            HStack(alignment: .center, spacing: ClipinChrome.groupGap) {
                ClipinSymbolOrb(systemImage: tab.icon, size: 58, iconSize: 20)

                ClipinSectionIntro(
                    title: tab.title,
                    subtitle: tab.summary,
                    eyebrow: "Preferences",
                    titleFontSize: 21
                )

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Shared Primitives

    var groupDivider: some View {
        Rectangle()
            .fill(ClipinInk.tertiary.opacity(colorScheme == .dark ? 0.16 : 0.12))
            .frame(height: 1)
    }

    var settingsSelectionPlaceholder: some View {
        contentGroup(padding: ClipinChrome.groupGap) {
            ClipinSectionIntro(
                title: "Choose a section",
                subtitle: "Select a section from the sidebar to edit Clipin preferences.",
                eyebrow: "Preferences",
                titleFontSize: 18,
                subtitleFontSize: 12
            )
        }
    }

    // MARK: - Row Builders

    func settingFieldRow<Control: View>(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey? = nil,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: description == nil ? .firstTextBaseline : .top, spacing: ClipinChrome.groupGap) {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                if let description {
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
        }
    }

    func toggleSettingRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        note: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)

                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    /// `LocalizedStringKey` overload — used when the description is a static string literal.
    func actionRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(title: title, descriptionText: Text(description),
                  buttonTitle: buttonTitle, busyTitle: busyTitle,
                  isBusy: isBusy, action: action)
    }

    /// `String` overload — used for runtime-assembled descriptions (e.g. containing version numbers).
    /// Do not use `LocalizedStringKey` here; SwiftUI would re-query `Localizable.strings`.
    func actionRow(
        _ title: LocalizedStringKey,
        description: String,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(title: title, descriptionText: Text(description),
                  buttonTitle: buttonTitle, busyTitle: busyTitle,
                  isBusy: isBusy, action: action)
    }

    private func actionRow(
        title: LocalizedStringKey,
        descriptionText: Text,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey?,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                descriptionText
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: action) {
                progressButtonLabel(
                    title: isBusy ? (busyTitle ?? buttonTitle) : buttonTitle,
                    isBusy: isBusy
                )
            }
                .buttonStyle(.bordered)
                .disabled(isBusy || activeOperation != nil)
        }
    }

    func progressButtonLabel(title: LocalizedStringKey, isBusy: Bool) -> some View {
        HStack(spacing: ClipinChrome.gap) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
            }
            Text(title)
        }
    }

    func infoCallout(icon: String, tint: Color, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        // firstTextBaseline 让 SwiftUI 按标题文字基线对齐 SF 图标，无魔数偏移。
        HStack(alignment: .firstTextBaseline, spacing: ClipinChrome.groupGap) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))

                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
    }

    func contentGroup<Content: View>(
        padding: CGFloat = ClipinChrome.groupGap,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(
                ClipinContentSurface(cornerRadius: ClipinChrome.cornerSurface)
            )
    }

    // MARK: - Utilities

    func openExternalURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func relativeString(from date: Date, to now: Date) -> String {
        Self._relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let _relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
