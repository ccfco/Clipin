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
}
