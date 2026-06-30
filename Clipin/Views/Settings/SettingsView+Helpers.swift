import SwiftUI

extension SettingsView {

    // MARK: - Native Form Row Builders
    //
    // 原生 System Settings 风格：行渲染交给 grouped Form，标题 + 副说明走「双行 Label」
    // 习惯用法（Form 行内自动竖排：标题在上、caption 副说明在下），控件落在行尾。
    // 不再自绘 contentGroup / surface / 手动 divider —— 这些由 Section + Form 提供。

    /// 标题 + 可选 caption 副说明，用作 Toggle / Picker / LabeledContent 的 label。
    @ViewBuilder
    func rowLabel(_ title: LocalizedStringKey, _ description: LocalizedStringKey? = nil) -> some View {
        Text(title)
        if let description {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// String 版副说明——运行时拼装的文案（含版本号 / 相对时间）不能用 LocalizedStringKey，
    /// 否则 SwiftUI 会再去 Localizable.strings 查一次找不到键。
    @ViewBuilder
    func rowLabel(_ title: LocalizedStringKey, descriptionText: String) -> some View {
        Text(title)
        Text(descriptionText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// 开关行：标题 + 副说明 + 行尾 Switch。
    func toggleRow(
        _ title: LocalizedStringKey,
        _ description: LocalizedStringKey,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            rowLabel(title, description)
        }
    }

    /// 动作行：标题 + 副说明 + 行尾按钮（带 busy spinner）。
    func actionRow(
        _ title: LocalizedStringKey,
        descriptionText: Text,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent {
            Button(action: action) {
                progressButtonLabel(
                    title: isBusy ? (busyTitle ?? buttonTitle) : buttonTitle,
                    isBusy: isBusy
                )
            }
            .disabled(isBusy || activeOperation != nil)
        } label: {
            Text(title)
            descriptionText
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    func actionRow(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(title, descriptionText: Text(description),
                  buttonTitle: buttonTitle, busyTitle: busyTitle,
                  isBusy: isBusy, action: action)
    }

    func actionRow(
        _ title: LocalizedStringKey,
        description: String,
        buttonTitle: LocalizedStringKey,
        busyTitle: LocalizedStringKey? = nil,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        actionRow(title, descriptionText: Text(description),
                  buttonTitle: buttonTitle, busyTitle: busyTitle,
                  isBusy: isBusy, action: action)
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
