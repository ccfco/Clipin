import AppKit
import SwiftUI

@MainActor
final class OnboardingFlow: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case workflow
        case permission

        var id: Int { rawValue }
    }

    @Published private(set) var step: Step = .welcome

    private let permission: PermissionManager
    private let onComplete: () -> Void

    init(permission: PermissionManager, onComplete: @escaping () -> Void) {
        self.permission = permission
        self.onComplete = onComplete
    }

    var canGoBack: Bool {
        step != .welcome
    }

    func reset() {
        step = .welcome
    }

    func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }

    func goBack() {
        move(-1)
    }

    func activatePrimary() {
        switch step {
        case .welcome, .workflow:
            move(1)
        case .permission:
            if permission.isAccessibilityGranted {
                onComplete()
            } else {
                permission.openSystemSettings()
            }
        }
    }

    /// 跳过权限步骤，直接以无权限模式启动（仅记录历史，不自动粘贴）
    func skipPermission() {
        onComplete()
    }
}

/// 首次启动引导。它不是功能清单，而是把 Clipin 的主路径和授权心智讲清楚。
struct OnboardingView: View {
    @ObservedObject var permission: PermissionManager
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 0) {
            header
            stage
            footer
        }
        .padding(ClipinChrome.shellGap)
        .frame(width: 560, height: 640)
        .clipinChromeGlass(cornerRadius: ClipinChrome.shellCornerRadius)
        .onAppear { permission.checkNow() }
        .accessibilityElement(children: .contain)
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
                    .foregroundStyle(ClipinInk.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(OnboardingFlow.Step.allCases) { candidate in
                    Capsule(style: .continuous)
                        .fill(candidate == flow.step ? Color.accentColor : ClipinHoverInk.fill)
                        .frame(width: candidate == flow.step ? 24 : 8, height: 8)
                }
            }
            .animation(ClipinMotion.feedback, value: flow.step)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var stage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            stageContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(ClipinMotion.panel, value: flow.step)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch flow.step {
        case .welcome:
            welcomeStage
        case .workflow:
            workflowStage
        case .permission:
            permissionStage
        }
    }

    private var welcomeStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            surface(cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 22) {
                        welcomeCopy
                        heroArtwork
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        welcomeCopy
                        heroArtwork
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            HStack(alignment: .top, spacing: 10) {
                featureCard(icon: "sparkles", title: "Keyboard-first", message: "Open, filter, act, and paste without leaving the home row.")
                featureCard(icon: "text.viewfinder", title: "Search images too", message: "OCR keeps screenshots and image snippets searchable with plain text.")
                featureCard(icon: "lock.shield", title: "Private by default", message: "Everything stays local, and sensitive clipboard writes are skipped.")
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var workflowStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            surface(cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
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

            surface(cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
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
            surface(cornerRadius: ClipinChrome.sectionCornerRadius, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader(
                        title: permission.isAccessibilityGranted ? "You are ready to paste straight back into any app." : "One system permission unlocks the last step.",
                        subtitle: permission.isAccessibilityGranted
                            ? "Accessibility access is on. Clipin can now send the selected item straight back to the current app."
                            : "Accessibility access lets Clipin return the selected item to the current app the moment you press Return."
                    )

                    surface(cornerRadius: ClipinChrome.detailStageCornerRadius, padding: 16) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(permission.isAccessibilityGranted ? Color.green.opacity(0.18) : ClipinSelectionInk.fill)
                                Image(systemName: permission.isAccessibilityGranted ? "checkmark.circle.fill" : "keyboard.badge.ellipsis")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(permission.isAccessibilityGranted ? Color.green : Color.accentColor)
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
                                .foregroundStyle(ClipinInk.secondary)
                            }

                            Spacer()
                            statusChip(permission.isAccessibilityGranted ? "Ready" : "Pending", granted: permission.isAccessibilityGranted)
                        }
                    }

                    surface(cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            permissionStep("1", text: "Open System Settings.")
                            permissionStep("2", text: "Find Clipin in Privacy & Security → Accessibility.")
                            permissionStep("3", text: "Turn it on, then come back here.")
                        }
                    }
                }
            }

            surface(cornerRadius: ClipinChrome.cardCornerRadius, padding: 16) {
                Label("Without Accessibility, Clipin can save history but cannot paste back into other apps. Turn it on to finish setup.", systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // 权限步骤未授权：用"稍后再说"替换 hint 文字；其余步骤保持原样
            if flow.step == .permission && !permission.isAccessibilityGranted {
                Button("Maybe later") { flow.skipPermission() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(ClipinInk.tertiary)
            } else {
                Text(footerHint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            // Back 按钮：权限步骤未授权时隐藏（Esc 仍可回退，且有"稍后再说"可以退出）
            if flow.canGoBack && (flow.step != .permission || permission.isAccessibilityGranted) {
                secondaryButton("Back") { flow.goBack() }
                    .keyboardShortcut(.cancelAction)
            }

            primaryButton(primaryTitle, systemImage: primaryIcon, action: primaryAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .clipinChromeGlass(cornerRadius: ClipinChrome.sectionCornerRadius)
    }

    private var primaryTitle: LocalizedStringKey {
        switch flow.step {
        case .welcome, .workflow:
            return "Continue"
        case .permission:
            return permission.isAccessibilityGranted ? "Open Clipin" : "Open System Settings"
        }
    }

    private var primaryIcon: String {
        switch flow.step {
        case .welcome, .workflow: return "arrow.right"
        case .permission: return permission.isAccessibilityGranted ? "return" : "gearshape"
        }
    }

    private var footerHint: LocalizedStringKey {
        switch flow.step {
        case .welcome:
            return "Use ← → to move. Press Return to continue."
        case .workflow:
            return "Use ← → to move. Press Return to continue, or Esc to go back."
        case .permission:
            return permission.isAccessibilityGranted
                ? "Press Return to open Clipin, or Esc to go back."
                : "Press Return to open System Settings, or Esc to go back."
        }
    }

    private func primaryAction() {
        flow.activatePrimary()
    }
}

private extension OnboardingView {
    var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClipinSectionIntro(
                title: "A calmer home for everything you copy.",
                subtitle: "Clipin stays quietly in your menu bar, keeps copied text, images, links, and files searchable, and lets you paste without breaking focus.",
                eyebrow: "Welcome",
                titleFontSize: 28
            )

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    shortcutBadge("Open Launcher", key: "⌘⇧V")
                    shortcutBadge("Paste", key: "↵")
                    shortcutBadge("Actions", key: "⌘K")
                }

                VStack(alignment: .leading, spacing: 8) {
                    shortcutBadge("Open Launcher", key: "⌘⇧V")
                    HStack(alignment: .top, spacing: 8) {
                        shortcutBadge("Paste", key: "↵")
                        shortcutBadge("Actions", key: "⌘K")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var heroArtwork: some View {
        ClipinSymbolOrb(systemImage: "clipboard.fill", size: 132, iconSize: 40)
        .frame(width: 176, height: 176)
    }

    func surface<Content: View>(cornerRadius: CGFloat, padding: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ClipinContentSurface(cornerRadius: cornerRadius))
    }

    func sectionHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        ClipinSectionIntro(title: title, subtitle: subtitle, titleFontSize: 27)
    }

    func shortcutBadge(_ label: LocalizedStringKey, key: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ClipinKeycap(key: key, foreground: ClipinInk.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .clipinChromeGlass(cornerRadius: ClipinChrome.badgeCornerRadius)
    }

    func featureCard(icon: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        surface(cornerRadius: ClipinChrome.cardCornerRadius, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    func workflowCard(index: String, title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        surface(cornerRadius: ClipinChrome.detailStageCornerRadius, padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(index)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ClipinInk.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    var workflowConnector: some View {
        Capsule(style: .continuous)
            .fill(ClipinSelectionInk.stroke.opacity(0.7))
            .frame(width: 18, height: 2)
            .padding(.top, 28)
    }

    func hintCard(title: String, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ClipinKeycap(key: title, foreground: ClipinInk.secondary)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(ClipinInk.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func permissionStep(_ number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func statusChip(_ text: LocalizedStringKey, granted: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(granted ? Color.green : ClipinInk.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background((granted ? Color.green.opacity(0.12) : ClipinHoverInk.fill).clipShape(Capsule(style: .continuous)))
    }

    func primaryButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(ClipinSelectionInk.stroke, lineWidth: 0.75)
                        )
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    func secondaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 12.5, weight: .medium))
            .buttonStyle(.bordered)
    }
}
