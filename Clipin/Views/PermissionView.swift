import SwiftUI

/// 辅助功能权限引导页
struct PermissionView: View {
    @ObservedObject var permission: PermissionManager

    var body: some View {
        VStack(spacing: 0) {
            // 顶部图标区
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 48)
            .padding(.bottom, 20)

            Text("Accessibility Permission Required")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 8)

            Text("Clipin needs Accessibility Permission to automatically paste content into the current app after you select a history item.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)

            // 步骤说明
            VStack(alignment: .leading, spacing: 12) {
                StepRow(number: "1", text: "Step 1: Click the button below to open System Settings.")
                StepRow(number: "2", text: "Step 2: Find Clipin under Privacy & Security \u{2192} Accessibility.")
                StepRow(number: "3", text: "Step 3: Enable the toggle and return.")
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)

            // 操作按钮
            Button {
                permission.openSystemSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                    Text("Open System Settings")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
        .frame(width: 400, height: 420)
        .background(.regularMaterial)
    }
}

private struct StepRow: View {
    let number: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
