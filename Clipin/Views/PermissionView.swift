import SwiftUI

/// 辅助功能权限引导页（独立窗口，非 onboarding 路径）
struct PermissionView: View {
    @ObservedObject var permission: PermissionManager
    var onSkip: (() -> Void)? = nil
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var glass: ClipinGlassPalette {
        .make(theme: settings.visualTheme, colorScheme: colorScheme)
    }

    private var hierarchy: ClipinPanelHierarchy {
        .make(glass: glass, colorScheme: colorScheme)
    }

    var body: some View {
        ZStack {
            ClipinShellBackground(glass: glass)
                .ignoresSafeArea()

            VStack(spacing: ClipinChrome.shellGap) {
                topStage
                permissionSteps
                bottomStrip
            }
            .padding(ClipinChrome.shellGap)
        }
        .frame(width: 430, height: 486)
        .shadow(color: .black.opacity(0.16), radius: 48, y: 24)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }

    private var topStage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ClipinSymbolOrb(
                    systemImage: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "keyboard.badge.ellipsis",
                    glass: glass,
                    hierarchy: hierarchy,
                    size: 62,
                    iconSize: 22
                )

                ClipinSectionIntro(
                    title: permission.isAccessibilityGranted ? "Clipin is ready to paste back into any app." : "One permission unlocks the final step.",
                    subtitle: permission.isAccessibilityGranted
                        ? "Accessibility access is on. Clipin can now return the selected item straight to the current app."
                        : "Accessibility access lets Clipin send the selected item back to the current app the moment you press Return.",
                    hierarchy: hierarchy,
                    eyebrow: "Accessibility",
                    titleFontSize: 21
                )
            }

            HStack(spacing: 10) {
                Label(permission.isAccessibilityGranted ? "Granted" : "Pending", systemImage: permission.isAccessibilityGranted ? "checkmark.seal.fill" : "clock")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(permission.isAccessibilityGranted ? Color.green : hierarchy.support.subduedInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(permission.isAccessibilityGranted ? Color.green.opacity(0.14) : glass.controlFill)
                    )

                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinSurfaceBackground(
                role: .column,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
    }

    private var permissionSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Turn this on in System Settings")
                    .font(.system(size: 13, weight: .semibold))

                Text("Clipin stays local and can record history without this access, but automatic paste needs Accessibility permission.")
                    .font(.system(size: 12))
                    .foregroundStyle(hierarchy.support.subduedInk)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                permStepRow("1", text: "Open System Settings.")
                permStepRow("2", text: "Find Clipin in Privacy & Security → Accessibility.")
                permStepRow("3", text: "Turn it on, then come back here.")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinSurfaceBackground(
                role: .grouped,
                cornerRadius: ClipinChrome.cardCornerRadius,
                glass: glass
            )
        )
    }

    private var bottomStrip: some View {
        HStack(spacing: 10) {
            Group {
                if permission.isAccessibilityGranted {
                    Text("Clipin will restart automatically to apply the permission.")
                        .foregroundStyle(Color.green.opacity(0.84))
                } else if let onSkip {
                    Button("Skip for now") { onSkip() }
                        .buttonStyle(.plain)
                        .foregroundStyle(hierarchy.support.hintInk)
                } else {
                    Text("Clipin will restart automatically after permission is granted.")
                        .foregroundStyle(hierarchy.support.hintInk)
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
                    .foregroundStyle(glass.emphasisOnStrongFill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(permission.isAccessibilityGranted ? Color.green.opacity(0.80) : glass.emphasisStrongFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(glass.emphasisStroke, lineWidth: 0.75)
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(permission.isAccessibilityGranted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ClipinSurfaceBackground(
                role: .strip,
                cornerRadius: ClipinChrome.sectionCornerRadius,
                glass: glass
            )
        )
    }

    private func permStepRow(_ number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(glass.emphasisStrongFill)
                )
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(hierarchy.support.subduedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
