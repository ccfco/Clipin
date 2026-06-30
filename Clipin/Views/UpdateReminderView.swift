import SwiftUI

struct UpdateReminderView: View {
    /// 浮层宽度的单一真相源：窗口 frame 与视图 `.frame(width:)` 共用，
    /// 避免两处写死 360 漂移导致 fittingSize 高度算错。
    static let preferredWidth: CGFloat = 360

    @ObservedObject var settings: SettingsStore
    let release: ReleaseInfo
    let onLater: () -> Void
    let onViewRelease: () -> Void
    let onDownload: () -> Void

    var body: some View {
        ZStack {
            Color.clear
                .clipinChromeGlass(cornerRadius: ClipinChrome.cornerShell)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                HStack(alignment: .top, spacing: ClipinChrome.groupGap) {
                    ClipinSymbolOrb(
                        systemImage: "arrow.down.circle.fill",
                        size: 48,
                        iconSize: 18
                    )

                    VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                        Text("New update available")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)

                        Text(
                            String(
                                format: NSLocalizedString("Clipin %@ is ready to install.", comment: ""),
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
                        .padding(ClipinChrome.groupGap)
                        .background(
                            ClipinContentSurface(cornerRadius: ClipinChrome.cornerSurface)
                        )
                }

                HStack(spacing: ClipinChrome.gap) {
                    Button("Later", action: onLater)
                        .buttonStyle(.glass)

                    Button("View Release", action: onViewRelease)
                        .buttonStyle(.glass)

                    Spacer(minLength: 0)

                    Button("Install Update", action: onDownload)
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(ClipinChrome.groupGap)
        }
        .frame(width: Self.preferredWidth)
    }
}
