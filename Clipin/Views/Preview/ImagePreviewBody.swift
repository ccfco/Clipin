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

    @State private var loaded: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(decorative: loaded, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
            } else if failed {
                placeholder()
            } else {
                // 解码中：保留 frame 占位，避免外层布局抖动
                Color.clear.frame(maxWidth: .infinity, maxHeight: maxHeight)
            }
        }
        .task(id: path) {
            failed = false
            // 命中即同步显示（避免首帧空白），未命中再 await 后台解码
            if let cached = ClipImageThumbnailCache.preview.cachedThumbnail(for: path) {
                loaded = cached
                return
            }
            loaded = nil
            let requestedPath = path
            let cg = await ClipImageThumbnailCache.preview.thumbnail(for: requestedPath)
            // 快速切换 item 时，旧 path 的解码结果可能在新 path 任务启动后才返回。
            // 必须同时检查取消状态 + path 一致，否则会用旧图覆盖正确预览。
            guard !Task.isCancelled, requestedPath == path else { return }
            if let cg {
                loaded = cg
            } else {
                failed = true
            }
        }
    }
}

