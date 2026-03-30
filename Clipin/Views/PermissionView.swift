import SwiftUI

/// 辅助功能权限引导页（独立窗口，非 onboarding 路径）
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
                // 图标
                ZStack {
                    Circle()
                        .fill(glass.emphasisFill)
                        .frame(width: 72, height: 72)
                    Image(systemName: "keyboard.badge.ellipsis")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(glass.emphasisInk)
                }
                .padding(.top, 28)
                .padding(.bottom, 14)

                Text("Accessibility Permission Required")
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.bottom, 8)

                Text("Clipin needs Accessibility Permission to automatically paste content into the current app after you select a history item.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)

                // 步骤卡片
                VStack(alignment: .leading, spacing: 10) {
                    permStepRow("1", text: "Open System Settings.")
                    permStepRow("2", text: "Find Clipin in Privacy & Security \u{2192} Accessibility.")
                    permStepRow("3", text: "Turn it on, then come back here.")
                }
                .padding(14)
                .background(
                    ClipinSurfaceBackground(
                        role: .grouped,
                        cornerRadius: ClipinChrome.cardCornerRadius,
                        glass: glass
                    )
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 20)

                // 主按钮
                Button {
                    permission.requestAndPoll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "gearshape")
                        Text(permission.isAccessibilityGranted ? "Permission Granted" : "Open System Settings")
                    }
                    .foregroundStyle(glass.emphasisOnStrongFill)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(permission.isAccessibilityGranted
                                  ? Color.green.opacity(0.8)
                                  : glass.emphasisStrongFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(glass.emphasisStroke, lineWidth: 0.75)
                            )
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(permission.isAccessibilityGranted)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)

                Text(permission.isAccessibilityGranted
                     ? "Restarting Clipin..."
                     : "Clipin will restart automatically after permission is granted.")
                    .font(.system(size: 12))
                    .foregroundStyle(permission.isAccessibilityGranted ? AnyShapeStyle(Color.green.opacity(0.8)) : AnyShapeStyle(.tertiary))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
            .padding(ClipinChrome.shellGap)
        }
        .frame(width: 400, height: 460)
        .shadow(color: .black.opacity(0.16), radius: 48, y: 24)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    private func permStepRow(_ number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(glass.emphasisInk)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
