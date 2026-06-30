import SwiftUI

extension SettingsView {

    // MARK: - Privacy Tab

    @ViewBuilder
    var privacyContent: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                    Text("Sensitive content is always excluded")
                        .font(.system(size: 13, weight: .medium))
                    Text("When apps like 1Password or Bitwarden mark content as sensitive, Clipin never records it. This cannot be turned off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            }
        }

        Section {
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
        Label {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text(noiseStatsTitle)
                    .font(.system(size: 13, weight: .medium))
                Text("Includes sensitive content from password managers and transient app writes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color.accentColor)
        }
    }

    private var noiseStatsTitle: String {
        String(
            format: NSLocalizedString("Blocked %d noisy clipboard write(s)", comment: ""),
            settings.noiseSkippedTotal
        )
    }
}
