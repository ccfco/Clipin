import SwiftUI

/// 辅助功能权限引导页（独立窗口，非 onboarding 路径）
struct PermissionView: View {
    @ObservedObject var permission: PermissionManager
    var onSkip: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.clear
                .clipinChromeGlass(cornerRadius: ClipinChrome.cornerShell)
                .ignoresSafeArea()

            // 三卡几乎填满窗口、整体内缩一个 gap 贴窗口四角:首卡贴上两角、末卡贴下两角,
            // 故内容卡圆角须降一档到 control(16=24−8)与窗口角同心,不用 surface(24)。
            VStack(spacing: ClipinChrome.gap) {
                topStage
                permissionSteps
                bottomStrip
            }
            .padding(ClipinChrome.gap)
        }
        .frame(width: 430, height: 486)
    }

    private var topStage: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            HStack(alignment: .center, spacing: ClipinChrome.groupGap) {
                ClipinSymbolOrb(
                    systemImage: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "keyboard.badge.ellipsis",
                    size: 62,
                    iconSize: 22
                )

                ClipinSectionIntro(
                    title: permission.isAccessibilityGranted ? "Clipin is ready to paste back into any app." : "One permission unlocks the final step.",
                    subtitle: permission.isAccessibilityGranted
                        ? "Accessibility access is on. Clipin can now return the selected item straight to the current app."
                        : "Accessibility access lets Clipin send the selected item back to the current app the moment you press Return.",
                    eyebrow: "Accessibility",
                    titleFontSize: 21
                )
            }

            HStack(spacing: ClipinChrome.gap) {
                Label(permission.isAccessibilityGranted ? "Granted" : "Pending", systemImage: permission.isAccessibilityGranted ? "checkmark.seal.fill" : "clock")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(permission.isAccessibilityGranted ? Color.green : ClipinInk.secondary)
                    .padding(.horizontal, ClipinChrome.gap)
                    .padding(.vertical, ClipinChrome.gap)
                    .background(
                        Capsule(style: .continuous)
                            .fill(permission.isAccessibilityGranted ? Color.green.opacity(0.14) : ClipinHoverInk.fill)
                    )

                Spacer(minLength: 0)
            }
        }
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinContentSurface(cornerRadius: ClipinChrome.cornerControl)
        )
    }

    private var permissionSteps: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                Text("Turn this on in System Settings")
                    .font(.system(size: 13, weight: .semibold))

                Text("Clipin stays local and can record history without this access, but automatic paste needs Accessibility permission.")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                permStepRow("1", text: "Open System Settings.")
                permStepRow("2", text: "Find Clipin in Privacy & Security → Accessibility.")
                permStepRow("3", text: "Turn it on, then come back here.")
            }
        }
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinContentSurface(cornerRadius: ClipinChrome.cornerControl)
        )
    }

    private var bottomStrip: some View {
        HStack(spacing: ClipinChrome.gap) {
            Group {
                if permission.isAccessibilityGranted {
                    Text("Clipin will restart automatically to apply the permission.")
                        .foregroundStyle(Color.green.opacity(0.84))
                } else if let onSkip {
                    Button("Skip for now") { onSkip() }
                        .buttonStyle(.plain)
                        .foregroundStyle(ClipinInk.tertiary)
                } else {
                    Text("Clipin will restart automatically after permission is granted.")
                        .foregroundStyle(ClipinInk.tertiary)
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            Button {
                permission.openSystemSettings()
            } label: {
                Label(permission.isAccessibilityGranted ? "Permission Granted" : "Open System Settings",
                      systemImage: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "gearshape")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, ClipinChrome.groupGap)
                    .padding(.vertical, ClipinChrome.gap)
                    .background(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                            .fill(permission.isAccessibilityGranted ? Color.green.opacity(0.80) : Color.accentColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous)
                                    .strokeBorder(ClipinSelectionInk.stroke, lineWidth: 0.75)
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(permission.isAccessibilityGranted)
        }
        .padding(.horizontal, ClipinChrome.groupGap)
        .padding(.vertical, ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipinChromeGlass(cornerRadius: ClipinChrome.cornerControl)
    }

    private func permStepRow(_ number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: ClipinChrome.gap) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                        .fill(Color.accentColor)
                )
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(ClipinInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
