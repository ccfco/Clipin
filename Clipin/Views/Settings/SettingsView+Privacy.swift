import SwiftUI

extension SettingsView {

    // MARK: - Privacy Tab

    var privacyContent: some View {
        VStack(spacing: contentStackSpacing) {
            contentGroup(padding: ClipinChrome.groupGap) {
                infoCallout(
                    icon: "checkmark.shield.fill",
                    tint: .green,
                    title: "Sensitive content is always excluded",
                    message: "When apps like 1Password or Bitwarden mark content as sensitive, Clipin never records it. This cannot be turned off."
                )
            }

            contentGroup {
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                    toggleSettingRow(
                        "Filter out drag-and-drop and app-generated clipboard writes",
                        description: "Skip clipboard writes that were not triggered by an explicit copy action so noisy transient items do not enter history.",
                        isOn: Binding(
                            get: { settings.skipTransientContent },
                            set: { settings.skipTransientContent = $0 }
                        )
                    )

                    if settings.noiseSkippedTotal > 0 {
                        groupDivider
                        noiseStatsRow
                    }
                }
            }
        }
    }

    /// "过滤器在工作"的证据——CLAUDE.md「不沉默成功」红线：用户开了过滤器需要看到
    /// 实际效果，否则无法判断 toggle 是否真的拦了什么。
    /// 不区分 transient vs concealed 拆分：用户视角只关心"屏蔽了多少噪声"。
    private var noiseStatsRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: ClipinChrome.gap) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(noiseStatsTitle)
                    .font(.system(size: 13, weight: .medium))

                Text("Includes sensitive content from password managers and transient app writes.")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var noiseStatsTitle: String {
        String(
            format: NSLocalizedString("Blocked %d noisy clipboard write(s)", comment: ""),
            settings.noiseSkippedTotal
        )
    }
}
