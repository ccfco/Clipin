import SwiftUI

struct UpdateReminderView: View {
    @ObservedObject var settings: SettingsStore
    let release: ReleaseInfo
    let onLater: () -> Void
    let onViewRelease: () -> Void
    let onDownload: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            ClipinShellBackground(glass: glass, cornerRadius: ClipinChrome.shellCornerRadius)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ClipinSymbolOrb(
                        systemImage: "arrow.down.circle.fill",
                        glass: glass,
                        hierarchy: hierarchy,
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
                        .foregroundStyle(hierarchy.support.subduedInk)
                    }

                    Spacer(minLength: 0)
                }

                if !release.notesPreview.isEmpty {
                    Text(release.notesPreview)
                        .font(.system(size: 11))
                        .foregroundStyle(hierarchy.support.subduedInk)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            ClipinSurfaceBackground(
                                role: .grouped,
                                cornerRadius: ClipinChrome.cardCornerRadius,
                                glass: glass
                            )
                        )
                }

                HStack(spacing: 8) {
                    Button("Later", action: onLater)
                        .buttonStyle(.bordered)

                    Button("View Release", action: onViewRelease)
                        .buttonStyle(.bordered)

                    Spacer(minLength: 0)

                    Button("Download Latest", action: onDownload)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
        }
        .frame(width: 360)
    }
}
