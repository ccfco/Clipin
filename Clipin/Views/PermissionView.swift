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

            Text("需要辅助功能权限")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 8)

            Text("Clipin 需要辅助功能权限，才能在你选择历史记录后\n自动将内容粘贴到当前应用。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.bottom, 32)

            // 步骤说明
            VStack(alignment: .leading, spacing: 12) {
                StepRow(number: "1", text: "点击下方按钮，打开系统设置")
                StepRow(number: "2", text: "在「隐私与安全性 → 辅助功能」中找到 Clipin")
                StepRow(number: "3", text: "打开开关，返回即可使用")
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 32)

            // 操作按钮
            Button {
                permission.openSystemSettings()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gear")
                    Text("打开系统设置")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 12)

            if permission.isAccessibilityGranted {
                Label("权限已授予", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.bottom, 24)
            } else {
                Text("授权后此窗口自动关闭")
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
    let text: String

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
