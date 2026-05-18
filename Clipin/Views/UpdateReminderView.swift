import SwiftUI

struct UpdateReminderView: View {
    @ObservedObject var settings: SettingsStore
    let release: ReleaseInfo
    let onLater: () -> Void
    let onViewRelease: () -> Void
    let onDownload: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .clipinChromeGlass(cornerRadius: ClipinChrome.shellCornerRadius)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ClipinSymbolOrb(
                        systemImage: "arrow.down.circle.fill",
                        size: 48,
                        iconSize: 18
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("New update available")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)

                        Text(
                            String(
                                format: NSLocalizedString("Clipin %@ is ready to download.", comment: ""),
                                release.displayVersion
                            )
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(ClipinInk.secondary)
                    }

                    Spacer(minLength: 0)
                }

                if !release.notesPreview.isEmpty {
                    Text(release.notesPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            ClipinContentSurface(cornerRadius: ClipinChrome.cardCornerRadius)
                        )
                }

                HStack(spacing: 8) {
                    Button("Later", action: onLater)
                        .buttonStyle(.glass)

                    Button("View Release", action: onViewRelease)
                        .buttonStyle(.glass)

                    Spacer(minLength: 0)

                    Button("Download Latest", action: onDownload)
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(18)
        }
        .frame(width: 360)
    }
}
