import AppKit
import SwiftUI

struct ImagePreviewBody: View {
    let item: ClipItem
    let searchQuery: String
    let vm: ClipboardViewModel
    /// 元数据底栏的徽章数据;底栏由 PreviewFadeFooterContainer 渲染在滚动区下方。
    let footerEntries: [PreviewPane.PreviewRailEntry]

    var body: some View {
        // 共享容器:负责滚动 + 底部渐隐遮罩 + 元数据底栏。
        // 旧实现内联 VStack + mask + 自管 contentHeight/scrollViewHeight,现由
        // PreviewFadeFooterContainer 单点收口,所有 preview body 视觉一致(决策见 CLAUDE.md)。
        PreviewFadeFooterContainer(footerEntries: footerEntries) {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                if let path = item.imagePath {
                    AsyncPreviewImage(path: path, maxHeight: 392) {
                        Label("Image not found", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 按 path 给图片叶子独立 identity：ImagePreviewBody 整体不再挂 .id（容器 diff 复用，
                    // 渲染更便宜），但持有 @State(loaded/placeholder) 的只有这个叶子——若它跨 item 复用，
                    // 新 path 的 .task 跑起来前首帧会闪上一张图。只重置这个叶子既防闪、又不全量重建整棵子树。
                    .id(path)
                } else {
                    Label("Image not found", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(ClipinInk.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let ocr = item.ocrText, !ocr.isEmpty {
                    ocrBlock(ocr)
                }
            }
        }
    }

    @ViewBuilder
    private func ocrBlock(_ ocr: String) -> some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            HStack(spacing: ClipinChrome.gap) {
                Label("OCR text", systemImage: "text.viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Spacer(minLength: 6)
                // 复制全部 OCR：用户场景是"截图里全是文字想一次性拿出来"，框选 N 屏太烦。
                OCRHeaderButton(systemImage: "doc.on.doc", title: "Copy all") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(ocr, forType: .string)
                    vm.showNotice(NSLocalizedString("OCR text copied", comment: ""))
                }
                .help("Copy all OCR text")
            }

            // OCR 文本一律完整展开（无折叠 / Show all）：截图 OCR 多是噪声，用
            // secondary 弱化、让图片占视觉重心；正文是自然高度的 SwiftUI Text，
            // 高度交给外层 ScrollView，默认在折叠线以下、滚动才露出。
            Text(ocrAttributedText(ocr))
                .font(.system(size: 13))
                .foregroundStyle(ClipinInk.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 把 OCR 文本转成 AttributedString，大小写不敏感高亮所有搜索命中。
    /// 命中处提到 primary 前景 + accent 底色，在 secondary 正文里跳出来。
    private func ocrAttributedText(_ ocr: String) -> AttributedString {
        var attributed = AttributedString(ocr)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return attributed }

        let ns = ocr as NSString
        var cursor = 0
        while cursor < ns.length {
            let found = ns.range(
                of: query,
                options: .caseInsensitive,
                range: NSRange(location: cursor, length: ns.length - cursor)
            )
            guard found.location != NSNotFound else { break }
            if let stringRange = Range(found, in: ocr),
               let lo = AttributedString.Index(stringRange.lowerBound, within: attributed),
               let hi = AttributedString.Index(stringRange.upperBound, within: attributed) {
                attributed[lo..<hi].backgroundColor = Color.accentColor.opacity(0.25)
                attributed[lo..<hi].foregroundColor = Color.primary
            }
            cursor = found.location + max(found.length, 1)
        }
        return attributed
    }
}

/// OCR 区块表头的次级动作按钮（Copy all）。
/// 安静设计：静止态无背景，仅 hover 浮出与 ClipinKeycap 同值的扁平胶囊填充——
/// 不上玻璃，避免之前玻璃胶囊在内容区里"突兀漂浮"。
struct OCRHeaderButton: View {
    let systemImage: String
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: ClipinChrome.gap) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(ClipinInk.secondary)
            .padding(.horizontal, ClipinChrome.gap)
            .padding(.vertical, ClipinChrome.gap)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(ClipinMotion.feedback) { isHovered = hovering }
        }
    }
}

/// 异步加载预览图片组件。
///
/// 旧实现走 `NSImage(contentsOfFile:)` 解码原图——5MB+ 4K 截屏会被解到全尺寸 bitmap，
/// preview 区高度只有 392pt，浪费一截内存和 CPU。当前实现走 `ClipImageThumbnailCache.preview`
/// 用 `CGImageSourceCreateThumbnailAtIndex` 解到 ~1024px，复用列表缩略图同套机制，
/// 内存上限可预测，重复来回切同一张图不再重解。
///
/// `.task(id: path)` 让 SwiftUI 在切换 item 时自动取消旧 task，无需手动判断。
struct AsyncPreviewImage<Placeholder: View>: View {
    let path: String
    let maxHeight: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    /// 清晰大图（预览档 ~1024px）。
    @State private var loaded: CGImage?
    /// 即时低清占位：列表行 24px 缩略图早已解码缓存，瞬时可取。大图首次落上来要现解码原图
    /// （多兆像素 PNG，最慢 ~100ms），期间若空白就是用户感知的「加载慢」。先把低清放大铺上去，
    /// 永不空白，清晰大图解出即无缝替换。
    @State private var lowResPlaceholder: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(decorative: loaded, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
            } else if let lowResPlaceholder {
                // 低清占位：medium 插值让放大不至于硬块状；它是过渡态，清晰图就绪即换。
                Image(decorative: lowResPlaceholder, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
            } else if failed {
                placeholder()
            } else {
                // 连低清占位都没有（图从未在列表解码过）：保留 frame 避免布局抖动。
                Color.clear.frame(maxWidth: .infinity, maxHeight: maxHeight)
            }
        }
        .task(id: path) {
            failed = false
            // 清晰大图已缓存：直接显示，无需占位、无解码延迟。
            if let cached = ClipImageThumbnailCache.preview.cachedThumbnail(for: path) {
                loaded = cached
                lowResPlaceholder = nil
                return
            }
            loaded = nil
            // 未命中清晰档：立刻铺列表小缩略图当占位（瞬时，消除空白），后台解清晰大图。
            lowResPlaceholder = ClipImageThumbnailCache.shared.cachedThumbnail(for: path)
            let requestedPath = path
            let cg = await ClipImageThumbnailCache.preview.thumbnail(for: requestedPath)
            // 快速切换 item 时，旧 path 的解码结果可能在新 path 任务启动后才返回。
            // 必须同时检查取消状态 + path 一致，否则会用旧图覆盖正确预览。
            guard !Task.isCancelled, requestedPath == path else { return }
            if let cg {
                loaded = cg
                lowResPlaceholder = nil
            } else if lowResPlaceholder == nil {
                // 清晰档解码失败且无占位兜底，才算真失败。
                failed = true
            }
        }
    }
}

