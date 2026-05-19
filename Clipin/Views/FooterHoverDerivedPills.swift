import SwiftUI

/// 底栏 hover 正上方派生玻璃胶囊。
///
/// 对齐真机 Raycast(本会话 screencapture 实证):hover 底栏某玻璃控件 →
/// 在其**正上方**派生独立玻璃 `Capsule` 胶囊(可多颗纵向堆叠),每颗显
/// `次级动作名 + 快捷键键帽`;无箭头连接、留小缝、同款暗玻璃;移开收起。
///
/// 取代旧实现"横向展开在 Paste 左侧"的 `isFooterHovered` 簇。纯鼠标可发现性
/// 增强;键盘用户走全局快捷键,不依赖此层(行为字节不变,仅呈现位置改)。
struct FooterDerivedPill: Identifiable {
    let label: String
    let shortcut: String
    let action: () -> Void
    /// 稳定 id(label+shortcut):hoverPills() 每次 body 重算会新建数组,
    /// 用 UUID 会让 ForEach 把同一动作当全新元素→hover/过渡整组重建闪动。
    var id: String { label + "\u{1}" + shortcut }
}

struct FooterHoverDerivedPills: View {
    let pills: [FooterDerivedPill]

    var body: some View {
        // 同一 GlassEffectContainer 内由系统融合(Apple:glass 不能采样 glass,
        // 必须容器内统一融合);克制动效(Apple "let glass rest in steady states")。
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(pills) { pill in
                    Button(action: pill.action) {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(pill.label))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(ClipinInk.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            ClipinKeycap(key: pill.shortcut, foreground: ClipinInk.secondary)
                        }
                    }
                    .buttonStyle(ClipinFooterGlassButtonStyle())
                }
            }
        }
    }
}
