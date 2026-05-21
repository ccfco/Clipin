import SwiftUI
import AppKit

/// 检测十六进制颜色字符串，返回 SwiftUI Color（#RGB / #RRGGBB / #RRGGBBAA）
/// 列表行用 hex-only：CSS 命名色（red/blue）误判率太高，rgb()/hsl() 留给预览面板。
func detectHexColor(in text: String) -> Color? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("#"), [4, 7, 9].contains(trimmed.count) else { return nil }
    let hex = String(trimmed.dropFirst())
    guard hex.allSatisfy(\.isHexDigit) else { return nil }

    var rgb: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&rgb) else { return nil }

    switch hex.count {
    case 3:
        let r = CGFloat((rgb >> 8) & 0xF) * 17 / 255
        let g = CGFloat((rgb >> 4) & 0xF) * 17 / 255
        let b = CGFloat(rgb & 0xF) * 17 / 255
        return Color(red: r, green: g, blue: b)
    case 6:
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    case 8:
        let r = CGFloat((rgb >> 24) & 0xFF) / 255
        let g = CGFloat((rgb >> 16) & 0xFF) / 255
        let b = CGFloat((rgb >> 8) & 0xFF) / 255
        let a = CGFloat(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b, opacity: a)
    default:
        return nil
    }
}

/// 预览面板专用色彩检测：hex 之外额外识别 `rgb()/rgba()/hsl()/hsla()`，
/// 并允许常见 CSS 属性包装（`color: #FF5733;` / `background: rgb(255,0,0)` 等）。
///
/// 不识别 CSS 命名色（red/blue/...）——日常文本里太常见，会大量 false positive
/// 把"早上吃了红薯"识别成颜色卡片。整段必须严格匹配（trim + 完整 prefix）。
///
/// 为什么要剥 CSS 包装：日常从 DevTools / 设计稿 / 代码里复制颜色时，复制范围常常
/// 是"整行 CSS 属性"而不是纯颜色值；如果不剥就会无法进入 ColorSwatch，用户必须
/// 手动把 `color: ` 那段删掉，这违背 launcher "复制就能用"的心智。
func detectColorForPreview(in text: String) -> Color? {
    if let hex = detectHexColor(in: text) { return hex }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    // 第一步：原文匹配 rgb()/hsl()
    if trimmed.hasPrefix("rgb") { return parseFunctionalRGB(trimmed) }
    if trimmed.hasPrefix("hsl") { return parseFunctionalHSL(trimmed) }

    // 第二步：剥 CSS 属性包装后再试
    if let stripped = stripCSSPropertyWrapper(trimmed) {
        if stripped.hasPrefix("#"), let hex = detectHexColor(in: stripped) { return hex }
        if stripped.hasPrefix("rgb") { return parseFunctionalRGB(stripped) }
        if stripped.hasPrefix("hsl") { return parseFunctionalHSL(stripped) }
    }
    return nil
}

/// 剥 `name: value;` 形式的 CSS 包装。
/// 接受常见 CSS 颜色属性名 whitelist，避免把 `time: 12:30` 误剥成颜色。
/// 返回 nil 表示不是已知颜色属性、不应继续尝试解析。
private func stripCSSPropertyWrapper(_ s: String) -> String? {
    guard let colonIdx = s.firstIndex(of: ":") else { return nil }
    let name = s[..<colonIdx].trimmingCharacters(in: .whitespaces)
    let knownProps: Set<String> = [
        "color", "background", "background-color",
        "fill", "stroke", "border-color", "outline-color",
        "caret-color", "accent-color", "text-decoration-color",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color",
    ]
    // CSS 自定义变量（`--brand-color: #fff` / `--accent: rgb(...)`）：现代设计系统标配，
    // Tailwind / shadcn / CSS-in-JS 大量使用；whitelist 漏掉会让用户复制变量行无法识别颜色
    let isCustomProperty = name.hasPrefix("--")
    guard knownProps.contains(name) || isCustomProperty else { return nil }
    var tail = s[s.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
    // 去掉行尾 ";" 和可能的 "!important"
    if tail.hasSuffix(";") { tail = String(tail.dropLast()) }
    tail = tail.replacingOccurrences(of: "!important", with: "")
        .trimmingCharacters(in: .whitespaces)
    return tail.isEmpty ? nil : tail
}

private func parseFunctionalRGB(_ s: String) -> Color? {
    // 接受 rgb(r, g, b) / rgba(r, g, b, a)；r/g/b 支持 0-255 整数或 0-100% 百分比；
    // a 支持 0-1 浮点或 0-100% 百分比。整段必须严格闭合，不允许残留字符。
    guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"),
          close == s.index(before: s.endIndex) else { return nil }
    let head = s[..<open]
    let isAlpha = head == "rgba" || head == "rgb"
    guard isAlpha else { return nil }
    let body = s[s.index(after: open)..<close]
    let parts = body.split(whereSeparator: { ", /".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 || parts.count == 4 else { return nil }

    func channel(_ token: String) -> CGFloat? {
        if token.hasSuffix("%") {
            guard let v = Double(token.dropLast()) else { return nil }
            return CGFloat(max(0, min(1, v / 100)))
        }
        guard let v = Double(token) else { return nil }
        return CGFloat(max(0, min(1, v / 255)))
    }

    func alpha(_ token: String) -> CGFloat? {
        if token.hasSuffix("%") {
            guard let v = Double(token.dropLast()) else { return nil }
            return CGFloat(max(0, min(1, v / 100)))
        }
        guard let v = Double(token) else { return nil }
        return CGFloat(max(0, min(1, v)))
    }

    guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
    // alpha token 存在但解析失败 → 返回 nil 让正文走文本预览，而不是静默兜底 1.0 把
    // `rgba(255,0,0,wat)` 这种格式错误也当成有效颜色显示（CLAUDE.md "不写 fallback" 红线）
    let a: CGFloat
    if parts.count == 4 {
        guard let parsed = alpha(parts[3]) else { return nil }
        a = parsed
    } else {
        a = 1
    }
    return Color(red: r, green: g, blue: b, opacity: a)
}

private func parseFunctionalHSL(_ s: String) -> Color? {
    guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"),
          close == s.index(before: s.endIndex) else { return nil }
    let head = s[..<open]
    guard head == "hsla" || head == "hsl" else { return nil }
    let body = s[s.index(after: open)..<close]
    let parts = body.split(whereSeparator: { ", /".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count == 3 || parts.count == 4 else { return nil }

    // hue: 接受度数（含 "deg" 或 "°" 后缀）、纯数字。turn/rad 罕见暂不支持。
    // "°" 必须识别：CSS 工具和 ColorSwatch 自己都常输出 "120°"，不识别就会出现
    // "从预览复制出去再粘进来不再识别为颜色"的自产自销不闭环。
    var hueToken = parts[0]
    if hueToken.hasSuffix("deg") { hueToken = String(hueToken.dropLast(3)) }
    else if hueToken.hasSuffix("°") { hueToken = String(hueToken.dropLast()) }
    guard let hueDeg = Double(hueToken) else { return nil }
    let h = CGFloat((hueDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360)

    func percent(_ token: String) -> CGFloat? {
        guard token.hasSuffix("%"), let v = Double(token.dropLast()) else { return nil }
        return CGFloat(max(0, min(1, v / 100)))
    }
    guard let saturation = percent(parts[1]), let lightness = percent(parts[2]) else { return nil }

    var alphaValue: CGFloat = 1
    if parts.count == 4 {
        let token = parts[3]
        if token.hasSuffix("%"), let v = Double(token.dropLast()) {
            alphaValue = CGFloat(max(0, min(1, v / 100)))
        } else if let v = Double(token) {
            alphaValue = CGFloat(max(0, min(1, v)))
        }
    }

    // HSL → RGB 标准转换
    let c = (1 - abs(2 * lightness - 1)) * saturation
    let hPrime = h * 6
    let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
    let (r1, g1, b1): (CGFloat, CGFloat, CGFloat)
    switch hPrime {
    case 0..<1: (r1, g1, b1) = (c, x, 0)
    case 1..<2: (r1, g1, b1) = (x, c, 0)
    case 2..<3: (r1, g1, b1) = (0, c, x)
    case 3..<4: (r1, g1, b1) = (0, x, c)
    case 4..<5: (r1, g1, b1) = (x, 0, c)
    default:    (r1, g1, b1) = (c, 0, x)
    }
    let m = lightness - c / 2
    return Color(red: r1 + m, green: g1 + m, blue: b1 + m, opacity: alphaValue)
}

/// URL 类型的列表 favicon 视图：与预览面板共享 FaviconCache 内存/磁盘缓存。
///
/// 两态设计（loading 与 fail 共用占位）：
/// 1. 字母圈占位 → 立即显示，作为"稳定 placeholder"
/// 2. favicon 拉到 → 无缝替换
///
/// 不画 loading→globe→favicon 三态，因为列表 row 比预览面板更频繁（每行一个），
/// 多一层中间状态会让列表滚动时出现"globe 一闪即过"的视觉噪声。
/// 字母圈本身已经是稳定的视觉锚点（同 host 永远同一个字母），用户不需要 globe 提示。
///
/// 接收完整 URL（而非 host）是因为同一 host 不同 port/scheme 是不同服务：
/// `http://112.44.253.74:9210` 和 `https://112.44.253.74` 是两个独立的 web 服务，
/// favicon 也可能完全不同。FaviconCache 按 origin (scheme://host:port) 缓存。
private struct RowFaviconView: View {
    let url: URL?
    @State private var image: NSImage?

    /// favicon 图在 24×24 块内的四周内缩——抓到的 favicon 多是满幅方图，
    /// 留这一圈让它和「SF 图标坐灰块上」的其它行图标视觉统一，而不是一整块彩色方图。
    private let glyphInset: CGFloat = 3

    var body: some View {
        ZStack {
            if let image {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(glyphInset)
            } else if let host = url?.host, !host.isEmpty {
                RowFaviconLetterMark(host: host)
            } else {
                // 解析不出 host（极少数 URL 字符串损坏） → 兜底 globe
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: url?.absoluteString ?? "") {
            image = nil
            guard let url, url.host?.isEmpty == false else { return }
            let fetched = await FaviconCache.shared.icon(for: url)
            // 快速切条目 / 列表滚动 row 复用时旧请求的网络响应可能晚到：
            // `.task(id:)` 在 id 变化时会自动取消旧 task，await 返回后 `Task.isCancelled`
            // 即为 true，直接丢弃陈旧结果。（闭包捕获的 `url` 是 task 创建时的值，
            // 不会变，所以不需要额外的 requestedURL == url 自比较。）
            guard !Task.isCancelled else { return }
            image = fetched
        }
    }
}

/// 列表版字母圈：灰底 + 单色首字母。
///
/// 与预览面板 `FaviconLetterMark` 的彩色 hue 版区别：
/// - 预览面板 64×64，是当前条目主角，可以承担彩色品牌识别角色
/// - 列表 row 24×24，同时显示十几个站点；如果用彩色 hue，多个字母圈会互相抢注意力
/// - 所以列表版用同样的 `primary.opacity(0.05)` 灰底（与其它 SF Symbol 容器一致）+
///   `primary.opacity(0.7)` 单色字母，维持列表整体的视觉静默
private struct RowFaviconLetterMark: View {
    let host: String

    private var letter: String {
        // 与预览面板 FaviconLetterMark 保持一致：去 www 后取首段首字母大写。
        // "docs.feishu.cn" → "D"; "www.github.com" → "G"; "localhost" → "L"
        let lower = host.lowercased()
        let parts = lower.split(separator: ".")
        let firstMeaningful = parts.first(where: { $0 != "www" }) ?? parts.first ?? Substring(host)
        return String(firstMeaningful.first ?? Character("?")).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            Text(letter)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.7))
        }
    }
}

private struct ClipThumbnailImage: View {
    let path: String
    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: path) {
            thumbnail = ClipImageThumbnailCache.shared.cachedThumbnail(for: path)
            if thumbnail == nil {
                let generatedThumbnail = await ClipImageThumbnailCache.shared.thumbnail(for: path)
                guard !Task.isCancelled else { return }
                thumbnail = generatedThumbnail
            }
        }
    }
}

/// 列表中的单行剪贴板项 — 极简单行布局
struct ClipItemRow: View {
    let item: ClipListItem
    var shortcutNumber: Int? = nil
    var searchQuery: String = ""
    var isSelected: Bool = false
    var isHovered: Bool = false
    /// 是否显示 ⌘1-9 快速粘贴数字提示(由"按住 ⌘"驱动)。
    var showsShortcutHint: Bool = false
    let sceneState: ClipinSceneState

    var body: some View {
        HStack(spacing: ClipinChrome.gap) {
            typeIndicator
                .scaleEffect(typeIndicatorScale)
                .animation(ClipinMotion.feedback, value: isHovered)

            Text(highlightedDisplayText)
                // 字重恒为 .regular:对齐 Raycast,选中行不再加粗——选中感全交给
                // accent 色 + 高亮底板,字重保持一致,整列文字粗细统一。
                .font(.system(size: 13.5, weight: .regular))
                // 未选 → 纯 primary(该黑的黑,对齐 Raycast 列表纯黑标题);
                // 选中 → accent(蓝),对齐 Spotlight 选中高亮心智(用户明确要求)。
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // pin 信号已交给左侧中性细 rail（ClipinSelectableRowBackground.isPinned），
            // 这里不再放 pin.fill icon，避免列表 row 视觉重量过高。

            if isSelected || hasShortcutBadge {
                trailingMeta
            }
        }
        // 文字↔选中底板 = edge（四边一致）。底板由外层 .background 紧贴本视图，
        // 故这层 padding 就是「文字到选中框」那段距离。
        .padding(.horizontal, ClipinChrome.gap)
        .padding(.vertical, ClipinChrome.gap)
        .animation(ClipinMotion.selection, value: isSelected)
        // reveal:按序号级联、从右侧划入,优雅铺开;dismiss:无延迟快收,松开即收。
        .animation(
            showsShortcutHint
                ? ClipinMotion.commandReveal.delay(shortcutRevealDelay)
                : ClipinMotion.feedback,
            value: showsShortcutHint
        )
    }

    /// 类型指示器：图片显示缩略图，颜色值显示色块，其他显示单色图标
    @ViewBuilder
    private var typeIndicator: some View {
        if item.clipType == .image, let path = item.imagePath,
           !path.isEmpty {
            ClipThumbnailImage(
                path: path
            )
        } else if item.clipType == .text, let color = detectHexColor(in: item.preview) {
            ZStack {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous).fill(color)
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .frame(width: 24, height: 24)
        } else if item.clipType == .url {
            // URL 类型：拿 favicon 代替通用 link 图标。传完整 URL（含 port + scheme），
            // FaviconCache 按 origin 缓存——同 host 不同 port 视为不同服务，因为
            // `http://192.168.1.1:8080` 和 `https://192.168.1.1` 是两个独立的 web service。
            // preview 就是 URL 字符串本身（ClipListItem 240 字符截断对 URL 几乎不影响解析）。
            RowFaviconView(url: URL(string: item.preview))
        } else {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
    }

    /// 列表前 9 行且当前按住 ⌘ 时,才显示数字徽标(Raycast 式 hold-to-reveal)。
    private var hasShortcutBadge: Bool {
        showsShortcutHint && shortcutNumber != nil
    }

    /// 数字徽标按序号做轻微级联:⌘1 最先浮现、⌘9 最后,营造从上到下铺开的节奏。
    private var shortcutRevealDelay: Double {
        guard let n = shortcutNumber else { return 0 }
        return Double(n - 1) * 0.02
    }

    /// trailing 区域:长按 ⌘ 时的纯数字徽标 + 选中行时间戳。
    /// 数字徽标在前 9 行均可浮现,时间戳仍仅选中行显示。
    private var trailingMeta: some View {
        HStack(spacing: ClipinChrome.gap) {
            if hasShortcutBadge, let n = shortcutNumber {
                shortcutBadge(n)
                    // 自粘贴项右缘冒出、向左滑到正确位置(.move 相对边缘,贴边进入)。
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if isSelected {
                Text(timeLabel)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(ClipinSelectionInk.dim)
            }
        }
    }

    /// ⌘1-9 数字徽标:圆角方块(cornerTile,`.continuous`),与键帽 / 筛选 chip /
    /// 图标块共用同一套 RoundedRectangle 圆角语言。固定 18×18 方形让 1-9 视觉统一。
    private func shortcutBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(ClipinInk.secondary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    private var typeIndicatorScale: CGFloat {
        if isSelected {
            return sceneState.selectedRowIconEmphasis
        }
        return isHovered ? 1.03 : 1.0
    }

    private var displayText: String { item.displayTitle }

    private var highlightedDisplayText: AttributedString {
        let text = displayText
        var result = AttributedString(text)

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }

        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex) {
            if let attrRange = Range(range, in: result) {
                result[attrRange].backgroundColor = ClipinSelectionInk.highlight
                // 命中词前景必须跟随选中态:选中行标题走 accent,这里若硬写 .primary
                // 会让命中字在选中行不变蓝(Codex 复审抓到)。
                result[attrRange].foregroundColor = isSelected ? .accentColor : .primary
            }
            searchStart = range.upperBound
        }

        return result
    }

    private var iconName: String { item.typeIconName }

    private var timeLabel: String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt) / 1000.0)
        if Calendar.current.isDateInToday(date) {
            return Self.timeFormatter.string(from: date)
        }
        return Self.dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()
}
