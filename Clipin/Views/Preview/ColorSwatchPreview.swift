import AppKit
import SwiftUI

struct ColorSwatchPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    /// 仅用于 showNotice 动作，不观察（避免随 vm 任意变化重渲染，破坏预览与导航解耦）。
    let vm: ClipboardViewModel
    let color: Color
    let originalText: String
    @State private var hoveredRow: String?

    private var nsColor: NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    /// 显示在 HEX 行的值：
    /// - 输入本身就是 #hex → 原样大写
    /// - 输入是 rgb()/hsl() → 用 nsColor 计算出标准 #RRGGBB（或 #RRGGBBAA 含透明度）
    /// 这样不论输入是哪种格式，三行 HEX/RGB/HSL 都有一致的"可复制"值。
    private var hexString: String {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return trimmed.uppercased() }
        let c = nsColor
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        let a = c.alphaComponent
        if a < 0.999 {
            let aInt = Int((a * 255).rounded())
            return String(format: "#%02X%02X%02X%02X", r, g, b, aInt)
        }
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            ZStack {
                // 浅灰底，当颜色有透明度时可见
                Color(nsColor: .controlBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous))
                RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
                    .fill(color)
                RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .frame(height: 120)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                colorRow("HEX", value: hexString)
                colorRow("RGB", value: rgbString)
                colorRow("HSL", value: hslString)
            }
        }
    }

    private func colorRow(_ label: String, value: String) -> some View {
        HStack(spacing: ClipinChrome.groupGap) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(colorScheme == .dark ? 0.78 : 0.68))
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(value, forType: .string)
                vm.showNotice(String(format: NSLocalizedString("%@ copied", comment: ""), label))
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                    .padding(.horizontal, ClipinChrome.gap)
                    .padding(.vertical, ClipinChrome.gap)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(hoveredRow == label ? 0.08 : 0))
                    )
            }
            .buttonStyle(.plain)
            .opacity(hoveredRow == label ? 1 : 0)
            // 守卫扫不到插值字面量，这里用 NSLocalizedString + format 显式本地化
            .help(String(format: NSLocalizedString("Copy %@", comment: "Tooltip: copy a color value, %@ = label like HEX/RGB"), label))
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredRow = hovering ? label : (hoveredRow == label ? nil : hoveredRow)
        }
    }

    private var rgbString: String {
        let c = nsColor
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return "rgb(\(r), \(g), \(b))"
    }

    private var hslString: String {
        let c = nsColor
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else {
            // 输出用 "deg" 后缀（CSS Level 3/4 都合规），让 parser 反向识别更稳；
            // "°" 在等宽字体里不显眼且部分工具不接受
            return "hsl(0deg, 0%, \(Int((l * 100).rounded()))%)"
        }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: CGFloat
        switch maxC {
        case r: h = (g - b) / d + (g < b ? 6 : 0)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h /= 6
        return "hsl(\(Int((h * 360).rounded()))deg, \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
    }
}

