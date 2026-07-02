import SwiftUI

extension SettingsView {

    // MARK: - Privacy Tab

    @ViewBuilder
    var privacyContent: some View {
        // 两个 section 都带标签，和 General/Storage 的分组标签惯例保持一致（首张卡片是
        // detailPane 注入的 paneHeader 介绍卡，故这里不承担"消除首 section 留白"的职责）。
        Section("Always protected") {
            calloutRow(
                systemImage: "checkmark.shield.fill",
                tint: .green,
                title: Text("Sensitive content is always excluded"),
                description: Text("When apps like 1Password or Bitwarden mark content as sensitive, Clipin never records it. This cannot be turned off.")
            )
        }

        Section("Filtering") {
            toggleRow(
                "Filter out drag-and-drop and app-generated clipboard writes",
                "Skip clipboard writes that were not triggered by an explicit copy action so noisy transient items do not enter history.",
                isOn: Binding(
                    get: { settings.skipTransientContent },
                    set: { settings.skipTransientContent = $0 }
                )
            )

            if settings.noiseSkippedTotal > 0 {
                noiseStatsRow
            }
        }
    }

    /// "过滤器在工作"的证据——CLAUDE.md「不沉默成功」红线：用户开了过滤器需要看到
    /// 实际效果，否则无法判断 toggle 是否真的拦了什么。
    /// 不区分 transient vs concealed 拆分：用户视角只关心"屏蔽了多少噪声"。
    private var noiseStatsRow: some View {
        calloutRow(
            systemImage: "shield.lefthalf.filled",
            tint: .accentColor,
            title: Text(noiseStatsTitle),
            description: Text("Includes sensitive content from password managers and transient app writes.")
        )
    }

    private var noiseStatsTitle: String {
        String(
            format: NSLocalizedString("Blocked %d noisy clipboard write(s)", comment: ""),
            settings.noiseSkippedTotal
        )
    }
}
