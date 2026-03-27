import AppKit
import SwiftUI

/// 首次启动引导。它不是功能清单，而是把 Clipin 的主路径和授权心智讲清楚。
struct OnboardingView: View {
    @ObservedObject var permission: PermissionManager
    let onComplete: (_ openPanel: Bool) -> Void

    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable, Identifiable {
        case welcome, workflow, permission
        var id: Int { rawValue }
    }

    private var glass: ClipinGlassPalette { .make(theme: settings.visualTheme, colorScheme: colorScheme) }
    private var hierarchy: ClipinPanelHierarchy { .make(glass: glass, colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
            footer
        }
        .padding(ClipinChrome.shellGap)
        .frame(width: 560, height: 640)
        .background(shellBackground)
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 42, y: 20)
        .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
        .onAppear { permission.checkNow() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Clipin")
                    .font(.system(size: 16, weight: .semibold))
                Text("Keyboard-first clipboard, refined for focus.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases) { candidate in
                    Capsule(style: .continuous)
                        .fill(candidate == step ? glass.emphasisStrongFill : glass.controlFill)
                        .frame(width: candidate == step ? 24 : 8, height: 8)
                }
            }
            .animation(ClipinMotion.feedback, value: step)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var stage: some View {
        ZStack {
            switch step {
            case .welcome: welcomeStage
            case .workflow: workflowStage
            case .permission: permissionStage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(ClipinMotion.panel, value: step)
    }

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            surface(role: .column, cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
                HStack(spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A calmer home for everything you copy.")
                            .font(.system(size: 30, weight: .semibold))
                        Text("Clipin stays quietly in your menu bar, keeps copied text, images, links, and files searchable, and lets you paste without breaking focus.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)

                        HStack(spacing: 8) {
                            shortcutBadge("Open Launcher", key: "⌘⇧V")
                            shortcutBadge("Paste", key: "↵")
                            shortcutBadge("Actions", key: "⌘K")
                        }
                    }

                    ZStack {
                        Circle()
                            .fill(glass.emphasisStrongFill.opacity(colorScheme == .dark ? 0.30 : 0.18))
                            .frame(width: 180, height: 180)
                            .blur(radius: 20)
                        Circle()
                            .fill(glass.emphasisFill)
                            .frame(width: 136, height: 136)
                        Image(systemName: "clipboard.fill")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundStyle(glass.emphasisInk)
                    }
                    .frame(width: 190, height: 190)
                }
            }

            HStack(spacing: 10) {
                featureCard(icon: "sparkles", title: "Keyboard-first", message: "Open, filter, act, and paste without leaving the home row.")
                featureCard(icon: "text.viewfinder", title: "Search images too", message: "OCR keeps screenshots and image snippets searchable with plain text.")
                featureCard(icon: "lock.shield", title: "Private by default", message: "Everything stays local, and sensitive clipboard writes are skipped.")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var workflowStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            surface(role: .column, cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader(title: "Three beats, then you are back to typing.", subtitle: "Clipin is built around one quiet loop: copy, open, confirm.")

                    HStack(alignment: .top, spacing: 10) {
                        workflowCard(index: "01", title: "Copy anything", message: "Clipin captures text, images, links, and complete file selections.")
                        workflowConnector
                        workflowCard(index: "02", title: "Press ⌘⇧V", message: "The launcher appears right where you work, ready to search and narrow.")
                        workflowConnector
                        workflowCard(index: "03", title: "Press Return", message: "Paste instantly, or stay in Continuous Paste mode for repeated drops.")
                    }
                }
            }

            surface(role: .grouped, cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
                HStack(spacing: 10) {
                    hintCard(title: "Tab", message: "Cycle clip types")
                    hintCard(title: "⌘K", message: "Open global actions")
                    hintCard(title: "⌘⇧L", message: "Keep pasting across apps")
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var permissionStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            surface(role: .column, cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader(
                        title: permission.isAccessibilityGranted ? "You are ready to paste straight back into any app." : "One system permission unlocks the last step.",
                        subtitle: permission.isAccessibilityGranted
                            ? "Accessibility access is on. Clipin can now send the selected item straight back to the current app."
                            : "Accessibility access lets Clipin return the selected item to the current app the moment you press Return."
                    )

                    surface(role: .contentStage, cornerRadius: ClipinChrome.detailStageCornerRadius, padding: 16) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(permission.isAccessibilityGranted ? Color.green.opacity(0.18) : glass.emphasisFill)
                                Image(systemName: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(permission.isAccessibilityGranted ? Color.green : glass.emphasisInk)
                            }
                            .frame(width: 52, height: 52)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Accessibility")
                                    .font(.system(size: 13, weight: .medium))
                                Text(
                                    permission.isAccessibilityGranted
                                        ? LocalizedStringKey("Granted")
                                        : LocalizedStringKey("Needed for automatic paste")
                                )
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            statusChip(permission.isAccessibilityGranted ? "Ready" : "Pending", granted: permission.isAccessibilityGranted)
                        }
                    }

                    surface(role: .grouped, cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            permissionStep("1", text: "Open System Settings.")
                            permissionStep("2", text: "Find Clipin in Privacy & Security → Accessibility.")
                            permissionStep("3", text: "Turn it on, then come back here.")
                        }
                    }
                }
            }

            surface(role: .grouped, cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
                Label("You can keep browsing and copying history without this. Automatic paste starts working as soon as the permission is enabled.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                secondaryButton("Back") { move(-1) }
            }

            Spacer()

            if step == .permission && !permission.isAccessibilityGranted {
                tertiaryButton("Maybe later") { onComplete(true) }
            }

            primaryButton(primaryTitle, systemImage: primaryIcon, action: primaryAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(ClipinSurfaceBackground(role: .strip, cornerRadius: ClipinChrome.sectionCornerRadius, glass: glass))
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome, .workflow: return "Continue"
        case .permission: return permission.isAccessibilityGranted ? "Open Clipin" : "Open System Settings"
        }
    }

    private var primaryIcon: String {
        step == .permission && !permission.isAccessibilityGranted ? "gearshape" : "arrow.right"
    }

    private func primaryAction() {
        switch step {
        case .welcome, .workflow:
            move(1)
        case .permission:
            permission.isAccessibilityGranted ? onComplete(true) : permission.openSystemSettings()
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }
}

private extension OnboardingView {
    var shellBackground: some View {
        RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                LinearGradient(colors: [glass.shellTintTop, glass.shellTintBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .overlay(
                LinearGradient(colors: [glass.shellWash, Color.clear], startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                LinearGradient(
                    colors: [glass.shellHighlight.opacity(colorScheme == .dark ? 0.16 : 0.36), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(glass.emphasisStrongFill.opacity(colorScheme == .dark ? 0.16 : 0.08))
                    .frame(width: 240, height: 240)
                    .blur(radius: 50)
                    .offset(x: -70, y: -90)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(glass.emphasisFill.opacity(colorScheme == .dark ? 0.24 : 0.14))
                    .frame(width: 220, height: 220)
                    .blur(radius: 44)
                    .offset(x: 70, y: 90)
            }
            .overlay(
                RoundedRectangle(cornerRadius: ClipinChrome.shellCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.22), lineWidth: 0.5)
            )
    }

    func surface<Content: View>(role: ClipinSurfaceRole, cornerRadius: CGFloat, padding: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClipinSurfaceBackground(role: role, cornerRadius: cornerRadius, glass: glass))
    }

    func sectionHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 27, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }

    func shortcutBadge(_ label: LocalizedStringKey, key: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            ClipinKeycap(key: key, foreground: hierarchy.command.ink.opacity(0.78), background: hierarchy.command.keycapFill)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ClipinSurfaceBackground(role: .control, cornerRadius: ClipinChrome.badgeCornerRadius, glass: glass))
    }

    func featureCard(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        surface(role: .grouped, cornerRadius: ClipinChrome.cardCornerRadius, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(glass.emphasisInk)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    func workflowCard(index: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        surface(role: .contentStage, cornerRadius: ClipinChrome.detailStageCornerRadius, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(index)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(hierarchy.selection.secondaryInk)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var workflowConnector: some View {
        VStack {
            Capsule(style: .continuous)
                .fill(glass.emphasisStroke.opacity(0.7))
                .frame(width: 18, height: 2)
                .padding(.top, 28)
            Spacer()
        }
    }

    func hintCard(title: String, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipinKeycap(key: title, foreground: hierarchy.command.ink.opacity(0.78), background: hierarchy.command.keycapFill)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func permissionStep(_ number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(glass.emphasisInk)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
    }

    func statusChip(_ text: LocalizedStringKey, granted: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(granted ? Color.green : hierarchy.command.ink.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((granted ? Color.green.opacity(0.12) : glass.controlFill).clipShape(Capsule(style: .continuous)))
    }

    func primaryButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(glass.emphasisOnStrongFill)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
    }

    func secondaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12.5, weight: .medium))
            .buttonStyle(.bordered)
    }

    func tertiaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
    }
}
