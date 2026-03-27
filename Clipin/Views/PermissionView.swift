import SwiftUI

/// 辅助功能权限引导页
struct PermissionView: View {
    @ObservedObject var permission: PermissionManager
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    LinearGradient(
                        colors: [glass.shellTintTop, glass.shellTintBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(glass.emphasisFill)
                        .frame(width: 84, height: 84)
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(glass.emphasisInk)
                }
                .padding(.top, 42)
                .padding(.bottom, 18)

                Text("Accessibility Permission Required")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 8)

                Text("Clipin needs Accessibility Permission to automatically paste content into the current app after you select a history item.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 12) {
                    StepRow(number: "1", text: "Step 1: Click the button below to open System Settings.", glass: glass)
                    StepRow(number: "2", text: "Step 2: Find Clipin under Privacy & Security \u{2192} Accessibility.", glass: glass)
                    StepRow(number: "3", text: "Step 3: Enable the toggle and return.", glass: glass)
                }
                .padding(16)
                .background(
                    ClipinSurfaceBackground(
                        role: .grouped,
                        cornerRadius: ClipinChrome.cardCornerRadius,
                        glass: glass
                    )
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 28)

                Button {
                    permission.openSystemSettings()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open System Settings")
                    }
                    .foregroundStyle(glass.emphasisOnStrongFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(glass.emphasisStrongFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(glass.emphasisStroke, lineWidth: 0.75)
                            )
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.bottom, 12)

                if permission.isAccessibilityGranted {
                    Label("Permission Granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.bottom, 24)
                } else {
                    Text("Window closes automatically after permission is granted")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
                }
            }
            .padding(22)
            .background(
                ClipinSurfaceBackground(
                    role: .column,
                    cornerRadius: ClipinChrome.sectionCornerRadius,
                    glass: glass
                )
            )
            .padding(ClipinChrome.shellGap)
        }
        .frame(width: 400, height: 420)
        .shadow(color: .black.opacity(0.16), radius: 48, y: 24)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

private struct StepRow: View {
    let number: String
    let text: LocalizedStringKey
    let glass: ClipinGlassPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(glass.emphasisInk)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
