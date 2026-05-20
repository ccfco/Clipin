import SwiftUI
import AppKit
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// 右侧预览面板
struct PreviewPane: View {
    let item: ClipItem?
    var searchQuery: String = ""
    let sceneState: ClipinSceneState
    @EnvironmentObject var vm: ClipboardViewModel

    /// metadata 预热触发器：item 切换时 `.task` 异步把 dimensions/fileSize/appIcon 写进
    /// PreviewMetadataCache，完成后 revision +1 强制 body 重建，此时 cached* 同步命中显示。
    /// 这是"body 永远不做主线程同步 IO"的关键桥；首次未命中那一瞬间相关 badge 暂时不显示，
    /// 比同步阻塞主线程更顺。
    @State private var metadataRevision: Int = 0

    var body: some View {
        Group {
            if let item {
                contentStage(for: item)
            } else if vm.selectedListItem != nil {
                // 已有选中行，但完整 ClipItem 还在后台 SQLite 读取中（或 ID-match guard
                // 拒绝了上一次选中的陈旧数据）。显式给一个安静的加载态，避免出现
                // "有内容 → 空占位 → 新内容" 的闪烁；正常路径 <16ms 看不到 spinner。
                contentStage {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                contentStage {
                    placeholder(
                        icon: "doc.text.magnifyingglass",
                        title: "Select an item",
                        subtitle: "Choose a clipboard item from the list to inspect it here."
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(sceneState.previewScale)
        .offset(y: sceneState.previewLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
        .task(id: item?.id) {
            await preloadMetadata(for: item)
        }
    }

    private func preloadMetadata(for item: ClipItem?) async {
        guard let item else { return }
        // 并发预热当前 item footer/source 需要的所有 metadata。
        // 完成后写 metadataRevision 触发重渲染，body 中 cached* 同步命中。
        await withTaskGroup(of: Void.self) { group in
            if let bundleID = item.sourceApp {
                group.addTask {
                    _ = await PreviewMetadataCache.shared.loadAppIcon(for: bundleID)
                }
            }
            switch item.clipType {
            case .image:
                if let path = item.imagePath {
                    group.addTask { _ = await PreviewMetadataCache.shared.loadDimensions(at: path) }
                    group.addTask { _ = await PreviewMetadataCache.shared.loadFileSize(at: path) }
                }
            case .file:
                let paths = FileClipboardContent.paths(from: item.content)
                if paths.count == 1, let path = paths.first {
                    group.addTask { _ = await PreviewMetadataCache.shared.loadFileSize(at: path) }
                    if Self.isImageFile(path) {
                        group.addTask { _ = await PreviewMetadataCache.shared.loadDimensions(at: path) }
                    }
                }
            case .text, .url:
                break
            }
        }
        // 触发 body 重建，让 cached* 路径同步命中
        metadataRevision &+= 1
    }

    private func contentStage(for item: ClipItem) -> some View {
        contentStage {
            content(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    previewFooter(for: item)
                        .padding(.top, 8)
                }
        }
    }

    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, ClipinChrome.floatingFooterBand)
    }

    private func previewFooter(for item: ClipItem) -> some View {
        let entries = footerEntries(for: item)
        return PreviewFooterRail(
            entries: entries
        )
        .opacity(sceneState.metadataOpacity)
        .offset(y: sceneState.metadataLift)
        .animation(ClipinMotion.focusShift, value: sceneState)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            if let color = detectColorForPreview(in: item.content) {
                ColorSwatchPreview(color: color, originalText: item.content)
                    .frame(maxWidth: 480, alignment: .leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                TextPreviewBody(
                    text: item.content,
                    font: previewTextFont(),
                    searchQuery: searchQuery
                )
                .environmentObject(vm)
                .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
            }

        case .url:
            URLPreviewView(
                urlString: item.content,
                searchQuery: searchQuery
            )
            .environmentObject(vm)

        case .image:
            // `.id(item.id)` 让 SwiftUI 在切换条目时把整棵 view 当新 view 重建，
            // 避免 @State ocrExpanded 从上一条目泄漏（用户展开 A 后切到 B 仍处于展开态）。
            ImagePreviewBody(item: item, searchQuery: searchQuery, vm: vm)
                .id(item.id)

        case .file:
            // 同上：fileIcons 虽然每次 .task 都会全量覆盖，但 .id 是更稳的防御，
            // 保证未来再加 @State 时不会无声地跨 item 携带状态。
            FilePreviewBody(item: item, searchQuery: searchQuery, vm: vm)
                .id(item.id)
        }
    }

    private func footerEntries(for item: ClipItem) -> [PreviewRailEntry] {
        var entries: [PreviewRailEntry] = []
        // 顺序即层级：source / pinned / OCR 这类"识别项"靠前，time / metric / formats / usage 这类"元数据"靠后。
        // 早期版本用 prominence 在字号/padding 上拉开 0.5–1pt 差异，但视觉差小到不可分，已删除。
        if let source = primarySourceBadge(for: item) {
            entries.append(PreviewRailEntry(item: source))
        }
        entries.append(PreviewRailEntry(item: timeBadge(for: item)))
        if let pinned = pinnedBadge(for: item) {
            entries.append(PreviewRailEntry(item: pinned))
        }
        entries.append(contentsOf: metricBadges(for: item).map(PreviewRailEntry.init))
        if let formats = formatsBadge(for: item) {
            entries.append(PreviewRailEntry(item: formats))
        }
        if let usage = usageBadge(for: item) {
            entries.append(PreviewRailEntry(item: usage))
        }
        if let ocr = ocrBadge(for: item) {
            entries.append(PreviewRailEntry(item: ocr))
        }
        return entries
    }

    private func metricBadges(for item: ClipItem) -> [PreviewBadgeItem] {
        var items: [PreviewBadgeItem] = []

        switch item.clipType {
        case .text:
            items.append(
                PreviewBadgeItem(
                    id: "characters",
                    title: String(
                        format: NSLocalizedString("%d chars", comment: ""),
                        displayCharacterCount(for: item.content)
                    ),
                    systemImage: "character"
                )
            )

            if let words = wordCount(for: item.content) {
                items.append(
                        PreviewBadgeItem(
                            id: "words",
                            title: String(format: NSLocalizedString("%d words", comment: ""), words),
                            systemImage: "textformat"
                        )
                    )
            }

        case .image:
            if let path = item.imagePath {
                // 全部走 PreviewMetadataCache 的 cached* 同步路径：未命中返回 nil，
                // 不显示对应 badge。.task 预热完成后下一帧自然补齐。
                if let dimensions = PreviewMetadataCache.shared.cachedDimensions(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "dimensions",
                            title: "\(dimensions.width) × \(dimensions.height)",
                            systemImage: "aspectratio"
                        )
                    )
                }

                if let size = PreviewMetadataCache.shared.cachedFileSize(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "file_size",
                            title: size,
                            systemImage: "internaldrive"
                        )
                    )
                }
            }

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            if paths.count > 1 {
                items.append(
                    PreviewBadgeItem(
                        id: "items",
                        title: String(format: NSLocalizedString("%d items", comment: ""), paths.count),
                        systemImage: "square.stack.3d.up"
                    )
                )
            }

            if let path = paths.first, paths.count == 1 {
                if let size = PreviewMetadataCache.shared.cachedFileSize(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "file_size",
                            title: size,
                            systemImage: "internaldrive"
                        )
                    )
                }

                if Self.isImageFile(path),
                   let dimensions = PreviewMetadataCache.shared.cachedDimensions(at: path) {
                    items.append(
                        PreviewBadgeItem(
                            id: "dimensions",
                            title: "\(dimensions.width) × \(dimensions.height)",
                            systemImage: "aspectratio"
                        )
                    )
                }
            }

        case .url:
            break
        }

        return items
    }

    private static func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func displayCharacterCount(for text: String) -> Int {
        text.count
    }

    private func wordCount(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        let language = NLLanguageRecognizer.dominantLanguage(for: trimmed)
        if let language {
            tokenizer.setLanguage(language)
        }

        if shouldHideWordCount(for: language) {
            return nil
        }

        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            count += 1
            return true
        }

        return count > 0 ? count : nil
    }

    private func shouldHideWordCount(for language: NLLanguage?) -> Bool {
        guard let language else { return false }
        switch language {
        case .simplifiedChinese, .traditionalChinese, .japanese, .korean:
            return true
        default:
            return false
        }
    }

    private func primarySourceBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard let sourceName = item.sourceName else { return nil }
        // 走 PreviewMetadataCache.cachedAppIcon 同步路径，未命中返回 nil badge 仍显示文字。
        // .task 预热完成后下一帧补齐 icon。
        let icon = item.sourceApp.flatMap { PreviewMetadataCache.shared.cachedAppIcon(for: $0) }
        return PreviewBadgeItem(
            id: "source",
            title: sourceName,
            icon: icon
        )
    }

    private func timeBadge(for item: ClipItem) -> PreviewBadgeItem {
        PreviewBadgeItem(
            id: "copied",
            title: relativeDate(item.createdAt),
            systemImage: "clock",
            helpText: Self.absoluteDateString(item.createdAt)
        )
    }

    private func pinnedBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.isPinned else { return nil }
        return PreviewBadgeItem(
            id: "pinned",
            title: NSLocalizedString("Pinned", comment: ""),
            systemImage: "pin.fill"
        )
    }

    /// 使用频率 badge：粘贴次数优先（更能反映真实使用价值），否则展示复制次数
    private func usageBadge(for item: ClipItem) -> PreviewBadgeItem? {
        if item.pasteCount > 0 {
            return PreviewBadgeItem(
                id: "usage",
                title: item.pasteCount == 1
                    ? NSLocalizedString("Pasted once", comment: "")
                    : String(format: NSLocalizedString("Pasted %d times", comment: ""), item.pasteCount),
                systemImage: "arrow.up.doc"
            )
        }
        if item.copyCount > 1 {
            return PreviewBadgeItem(
                id: "usage",
                title: String(format: NSLocalizedString("%d copies", comment: ""), item.copyCount),
                systemImage: "square.on.square"
            )
        }
        return nil
    }

    private var formatsDisplay: String {
        var labels: [String] = ["plain"]
        let utis = vm.selectedRepresentationUTIs
        if utis.contains("public.html") { labels.append("html") }
        if utis.contains("public.rtf")  { labels.append("rtf") }
        if utis.contains("public.rtfd") { labels.append("rtfd") }
        if utis.contains("public.url")  { labels.append("url") }
        return labels.joined(separator: " · ")
    }

    /// Formats badge：展示当前条目保留了哪些 representation（plain/html/rtf/rtfd/url）。
    /// 仅在文本/URL 条目，且除 plain 外还有其它格式时显示，避免对纯文本条目造成视觉噪声。
    private func formatsBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.clipType == .text || item.clipType == .url else { return nil }
        let display = formatsDisplay
        guard display != "plain" else { return nil }
        return PreviewBadgeItem(
            id: "formats",
            title: display,
            systemImage: "doc.richtext",
            helpText: NSLocalizedString("preview.metadata.formats", comment: "Formats label in preview metadata")
        )
    }

    private func ocrBadge(for item: ClipItem) -> PreviewBadgeItem? {
        guard item.clipType == .image,
              let ocr = item.ocrText, !ocr.isEmpty else { return nil }
        return PreviewBadgeItem(
            id: "ocr",
            title: NSLocalizedString("OCR", comment: ""),
            systemImage: "text.viewfinder"
        )
    }

    fileprivate struct PreviewBadgeItem: Identifiable {
        let id: String
        let title: String
        let systemImage: String?
        let icon: NSImage?
        let helpText: String?

        init(
            id: String,
            title: String,
            systemImage: String? = nil,
            icon: NSImage? = nil,
            helpText: String? = nil
        ) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
            self.icon = icon
            self.helpText = helpText
        }
    }

    fileprivate struct PreviewRailEntry: Identifiable {
        let item: PreviewBadgeItem
        var id: String { item.id }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: ClipinChrome.heroOrbCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(ClipinInk.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let _absoluteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    private static func absoluteDateString(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return _absoluteDateFormatter.string(from: date)
    }

    private static let _relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private func relativeDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return Self._relativeDateFormatter.localizedString(for: date, relativeTo: .now)
    }

    private struct TextPreviewBody: View {
        let text: String
        let font: NSFont
        let searchQuery: String
        @EnvironmentObject var vm: ClipboardViewModel

        /// JSON 自动 pretty-print：默认开启（更易读），允许切回 Raw 看原始压缩格式。
        /// 用 @State 让用户的选择保留在当前 item 视图生命周期内；切到下一条目重置回默认。
        @State private var renderMode: RenderMode = .auto

        enum RenderMode { case auto, raw }

        /// 把 JSON 字符串 pretty-print。检测 + 解析 + 序列化都在 body 里同步做：
        /// - 检测 O(1)（看首字符）
        /// - 解析/序列化是 JSONSerialization，对 KB 级 JSON 耗时 < 1ms
        /// - MB 级 JSON 解析虽慢但属于罕见路径，且 SelectableTextPreview 的哈希判等会让
        ///   text 不变时不重做 NSAttributedString，所以瓶颈只在首次切到该条目那一帧
        private var prettyJSON: String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed, .topLevelDictionaryAssumed]
                  ),
                  // 不能用 .sortedKeys：会改变 key 顺序，从 Pretty 模式框选复制时拿到的
                  // JSON 跟原始剪贴板不一致 —— 这是静默数据失真，比"键顺序乱"严重得多
                  let pretty = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .withoutEscapingSlashes]
                  ),
                  let result = String(data: pretty, encoding: .utf8) else {
                return nil
            }
            return result
        }

        var body: some View {
            let pretty = prettyJSON
            let isJSON = pretty != nil
            let displayText: String = {
                if let pretty, renderMode == .auto { return pretty }
                return text
            }()

            VStack(alignment: .leading, spacing: 8) {
                // 仅当检测到 JSON 时才显示 toggle，避免对普通文本造成视觉噪声
                if isJSON {
                    HStack(spacing: 8) {
                        Label("JSON", systemImage: "curlybraces")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ClipinInk.secondary)
                        Spacer(minLength: 6)
                        Button {
                            renderMode = renderMode == .auto ? .raw : .auto
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: renderMode == .auto ? "text.alignleft" : "text.justify.leading")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(renderMode == .auto ? "Show raw" : "Pretty")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(ClipinInk.secondary)
                            .clipinChromeGlass(in: Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(renderMode == .auto ? "Show original compact JSON" : "Pretty-print JSON")
                    }
                }

                SelectableTextPreview(
                    text: displayText,
                    // JSON pretty 用等宽字体阅读结构更清晰；普通文本仍走传入的 font
                    font: isJSON && renderMode == .auto
                        ? .monospacedSystemFont(ofSize: ClipinChrome.previewBodyFontSize, weight: .regular)
                        : font,
                    searchQuery: searchQuery,
                    vm: vm
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func previewTextFont() -> NSFont {
        .systemFont(ofSize: ClipinChrome.previewBodyFontSize, weight: .regular)
    }

}

/// 文件预览主体单独拆出来：承载多文件 icon 异步加载 + mini list。
/// 旧实现把"只显示首文件 + 全路径列表"硬塞到 PreviewPane.content inline，
/// 多选时其余文件只剩纯文本路径行 —— 视觉上完全丢了 Finder 多选语义。
private struct FilePreviewBody: View {
    let item: ClipItem
    let searchQuery: String
    let vm: ClipboardViewModel

    /// 缓存读出来的 file icon。SwiftUI 同步 body 不能直接 await，所以这里用
    /// @State 桥接：.task 异步预热 cache，完成后 fileIcons 更新触发重渲染，
    /// 渲染时直接走 PreviewMetadataCache 的 cached* 路径，永远不在主线程同步读 IconServices。
    @State private var fileIcons: [String: NSImage] = [:]

    /// mini list 最多展示多少行；超出折叠成 "+N more"。
    /// Finder 实测多选超过 8 个就开始体验冗余，8 是经验上限。
    private let maxRows = 8

    private var paths: [String] {
        FileClipboardContent.paths(from: item.content)
    }

    var body: some View {
        let allPaths = paths
        let primaryPath = allPaths.first ?? item.content
        let primaryURL = URL(fileURLWithPath: primaryPath)
        let singleImageFile = allPaths.count == 1 && isImageFile(primaryPath)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(primaryPath: primaryPath, primaryURL: primaryURL, paths: allPaths)

                if singleImageFile {
                    AsyncPreviewImage(path: primaryPath, maxHeight: 360) {
                        pathFallback(allPaths: allPaths)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if allPaths.count > 1 {
                    multiFileList(paths: allPaths)
                } else {
                    pathFallback(allPaths: allPaths)
                }
            }
        }
        .task(id: item.id) {
            // 预热前 maxRows 个 file icon；后续超出的折叠在 "+N more"，不需要异步拉
            await withTaskGroup(of: Void.self) { group in
                for path in paths.prefix(maxRows) {
                    group.addTask {
                        _ = await PreviewMetadataCache.shared.loadFileIcon(at: path)
                    }
                }
            }
            // 更新本地 @State 触发重渲染，body 重建时 cachedFileIcon 同步命中
            var snapshot: [String: NSImage] = [:]
            for path in paths.prefix(maxRows) {
                if let icon = PreviewMetadataCache.shared.cachedFileIcon(at: path) {
                    snapshot[path] = icon
                }
            }
            fileIcons = snapshot
        }
    }

    private func icon(for path: String) -> NSImage? {
        if let cached = fileIcons[path] { return cached }
        // 第一次 body 重建时 .task 还没跑完，先查 shared cache
        return PreviewMetadataCache.shared.cachedFileIcon(at: path)
    }

    @ViewBuilder
    private func header(primaryPath: String, primaryURL: URL, paths: [String]) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                if let img = icon(for: primaryPath) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 54, height: 54)
                }
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(FileClipboardContent.displayName(for: primaryPath))
                    .font(.system(size: 17, weight: .semibold))
                Text(fileHeaderSubtitle(paths: paths, primaryURL: primaryURL))
                    .font(.system(size: 12.5))
                    .foregroundStyle(ClipinInk.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func multiFileList(paths: [String]) -> some View {
        let shown = Array(paths.prefix(maxRows))
        let overflow = paths.count - shown.count

        VStack(alignment: .leading, spacing: 10) {
            Label("Selection", systemImage: "square.stack.3d.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown, id: \.self) { path in
                    HStack(spacing: 10) {
                        if let img = icon(for: path) {
                            Image(nsImage: img)
                                .resizable()
                                .frame(width: 18, height: 18)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: 18, height: 18)
                        }
                        Text(FileClipboardContent.displayName(for: path))
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if overflow > 0 {
                    Text(String(format: NSLocalizedString("+%d more", comment: ""), overflow))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ClipinInk.secondary)
                        .padding(.leading, 28)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pathFallback(allPaths: [String]) -> some View {
        let fileListText = allPaths.isEmpty ? item.content : allPaths.joined(separator: "\n")
        VStack(alignment: .leading, spacing: 10) {
            Label("Path", systemImage: "folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)
            SelectableTextPreview(
                text: fileListText,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                searchQuery: searchQuery,
                vm: vm
            )
            .frame(minHeight: 80)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func fileHeaderSubtitle(paths: [String], primaryURL: URL) -> String {
        let directory = primaryURL.deletingLastPathComponent().path
        guard paths.count > 1 else { return directory }
        return "\(FileClipboardContent.summaryLabel(for: paths.joined(separator: "\n"))) • \(directory)"
    }
}

/// 图片预览主体单独拆出来：承载 OCR 区块的"折叠/展开" @State。
/// 嵌在 PreviewPane.content(for:) inline 里没办法挂 @State，拆 struct 是最干净的做法。
private struct ImagePreviewBody: View {
    let item: ClipItem
    let searchQuery: String
    let vm: ClipboardViewModel
    @State private var ocrExpanded = false

    /// 折叠时 OCR 块高度上限；展开后让 OCR 跟随外层 ScrollView 自然延伸。
    /// 200pt 沿用原值，保证不会一上来就吃掉图片预览的视觉权重。
    private let collapsedOCRHeight: CGFloat = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let path = item.imagePath {
                    AsyncPreviewImage(path: path, maxHeight: 392) {
                        Label("Image not found", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 13))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.detailMediaCornerRadius, style: .continuous))
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func ocrBlock(_ ocr: String) -> some View {
        // 估算长度：极短 OCR（一两行字）直接铺开，没必要给 Show all 按钮；
        // 估算阈值用字符数粗算，避免依赖 NSLayoutManager 测高的同步开销。
        let isShortEnough = ocr.count < 200
        let effectivelyExpanded = isShortEnough || ocrExpanded

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("OCR text", systemImage: "text.viewfinder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Spacer(minLength: 6)
                // 复制全部 OCR：用户场景是"截图里全是文字想一次性拿出来"，
                // 框选 N 屏滚动太烦；这个按钮永远显示（短文本也可能想整段复制）
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(ocr, forType: .string)
                    vm.showNotice(NSLocalizedString("OCR text copied", comment: ""))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Copy all")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(ClipinInk.secondary)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Copy all OCR text")

                if !isShortEnough {
                    Button {
                        withAnimation(ClipinMotion.feedback) { ocrExpanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: ocrExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text(ocrExpanded ? "Collapse" : "Show all")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .foregroundStyle(ClipinInk.secondary)
                        .clipinChromeGlass(in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(ocrExpanded ? "Collapse OCR text" : "Show full OCR text")
                }
            }

            SelectableTextPreview(
                text: ocr,
                font: .systemFont(ofSize: 13, weight: .regular),
                searchQuery: searchQuery,
                vm: vm
            )
            .frame(
                minHeight: 72,
                // 展开后给一个大上限，让 OCR 占满外层 ScrollView 剩余空间；
                // 不用 .infinity 避免 SwiftUI ScrollView 内嵌 NSTextView 高度推算无穷。
                maxHeight: effectivelyExpanded ? 1600 : collapsedOCRHeight
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
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
private struct AsyncPreviewImage<Placeholder: View>: View {
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

private struct ColorSwatchPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var vm: ClipboardViewModel
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
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                // 浅灰底，当颜色有透明度时可见
                Color(nsColor: .controlBackgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous))
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .fill(color)
                RoundedRectangle(cornerRadius: ClipinChrome.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 10) {
                colorRow("HEX", value: hexString)
                colorRow("RGB", value: rgbString)
                colorRow("HSL", value: hslString)
            }
        }
    }

    private func colorRow(_ label: String, value: String) -> some View {
        HStack(spacing: 12) {
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
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(hoveredRow == label ? 0.08 : 0))
                    )
            }
            .buttonStyle(.plain)
            .opacity(hoveredRow == label ? 1 : 0)
            .help("Copy \(label)")
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

private struct PreviewValueBadge: View {
    let item: PreviewPane.PreviewBadgeItem

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            } else if let icon = item.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 11, height: 11)
            }

            Text(item.title)
                .font(.system(size: ClipinChrome.previewBadgeFontSize, weight: .medium, design: .rounded))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(ClipinInk.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .clipinChromeGlass(in: Capsule(style: .continuous))
        .help(item.helpText ?? item.title)
    }
}

private struct PreviewFooterRail: View {
    let entries: [PreviewPane.PreviewRailEntry]

    var body: some View {
        // 外层 previewFooter 已 .padding(.top, 8)，rail 内部不再重复加 top；
        // .horizontal/.bottom 1pt 是历史防 clip 残留（glass capsule 现已自带 padding），删除。
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(entries) { entry in
                    PreviewValueBadge(item: entry.item)
                }
            }
        }
    }
}

private struct SelectableTextPreview: NSViewRepresentable {
    let text: String
    let font: NSFont
    var searchQuery: String = ""
    weak var vm: ClipboardViewModel?

    /// NSDataDetector 创建并非零成本（底层是 NLP regex 状态机）。
    /// 文档明确表示 thread-safe，可以全局静态复用。
    static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    final class Coordinator {
        var lastTextHash: Int = 0
        var lastQueryHash: Int = 0
        var lastFontDescriptor: NSFontDescriptor?
        /// 文本不变时复用上次链接扫描结果；query/font 变化无需重扫
        var detectedLinks: [(NSRange, URL)] = []
        var hasInitialized = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.allowsUndo = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.autoresizingMask = [.width]
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 哈希判等：SwiftUI 外层 state 变动（scene state / selection / sceneState 抖动）
        // 都会触发 updateNSView，但实际我们只关心 (text, query, font) 三元组。
        // 之前用 textView.attributedString() != attributed 做判等会先 copy 整段 NSAttributedString
        // 再 deep-compare，对长文本是真实开销。
        let textHash = text.hashValue
        let queryHash = searchQuery.hashValue
        let coord = context.coordinator
        let textChanged = !coord.hasInitialized
            || textHash != coord.lastTextHash
            || coord.lastFontDescriptor != font.fontDescriptor
        let queryChanged = queryHash != coord.lastQueryHash

        guard textChanged || queryChanged else { return }

        let textColor = NSColor.labelColor
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: para
        ]
        let attributed = NSMutableAttributedString(string: text, attributes: attrs)

        // 搜索高亮
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let nsText = text as NSString
            var searchRange = NSRange(location: 0, length: nsText.length)
            let highlightBg = NSColor.controlAccentColor.withAlphaComponent(0.25)
            while searchRange.location < nsText.length {
                let found = nsText.range(of: query, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                attributed.addAttribute(.backgroundColor, value: highlightBg, range: found)
                searchRange.location = found.location + found.length
                searchRange.length = nsText.length - searchRange.location
            }
        }

        // 链接检测：text 变了才重扫，仅 query 变只复用上次结果
        if textChanged {
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            var links: [(NSRange, URL)] = []
            Self.linkDetector?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match, let url = match.url {
                    links.append((match.range, url))
                }
            }
            coord.detectedLinks = links
        }
        for (range, url) in coord.detectedLinks {
            attributed.addAttribute(.link, value: url, range: range)
        }

        textView.textStorage?.setAttributedString(attributed)
        if textChanged {
            // 文本变了重置选区，仅 query 变保留用户已选范围
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }

        coord.lastTextHash = textHash
        coord.lastQueryHash = queryHash
        coord.lastFontDescriptor = font.fontDescriptor
        coord.hasInitialized = true
    }
}

// MARK: - URL Preview

/// 远程 favicon 缓存：actor 串行化 + pending dedup + 磁盘持久化 + 多源回退。
///
/// 旧实现单上游写死 `google.com/s2/favicons`，重启即丢、且在中国大陆/离线场景容易长期 nil。
/// 当前实现：
/// 1. 启动即从磁盘 `~/Library/Application Support/Clipin/favicons/<host>.png` 异步读回
///    in-memory cache；
/// 2. 取 favicon 时按"直连 `/favicon.ico` → Google s2 兜底"顺序；
/// 3. 命中后异步写磁盘，TTL 7 天（避免站点换 favicon 后永久不更新）。
///
/// **关键设计：cache 持有 immutable `Data`（PNG），每次 `icon(for:)` 调用即时构造
/// 新的 `NSImage` 给 caller**。NSImage 内部 representations 可变非线程安全，如果让
/// UI 和后台磁盘写同一个 instance，会触发 race（AppKit 历史包袱：第一次 draw 时
/// lazy lock 到主线程，后台读 tiffRepresentation 同时绘制会并发 mutation）。
/// 把 cache 内层做成"序列化产物"，调用方每次都拿独立"渲染产物"，是唯一干净的解。
///
/// 拿不到就返回 nil，由调用方自己画 globe 占位，不在这里造假数据。
private actor FaviconCache {
    static let shared = FaviconCache()

    /// PNG-encoded immutable data。每次 caller 调用都构造新的 NSImage，避免共享可变实例。
    private var cache: [String: Data] = [:]
    private var pending: [String: Task<Data?, Never>] = [:]

    /// 7 天 TTL：favicon 改动频率远低于此，但也不至于让旧文件永远滞留。
    private static let diskTTL: TimeInterval = 7 * 24 * 3600

    private static let diskDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Clipin/favicons", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func icon(for host: String) async -> NSImage? {
        if let data = cache[host] { return NSImage(data: data) }
        if let task = pending[host] {
            if let data = await task.value { return NSImage(data: data) }
            return nil
        }

        // 磁盘命中：填充 in-memory 后返回
        if let data = readDisk(host: host) {
            cache[host] = data
            return NSImage(data: data)
        }

        let task = Task<Data?, Never> {
            await Self.fetchRemote(host: host)
        }
        pending[host] = task
        let result = await task.value
        pending[host] = nil
        if let data = result {
            cache[host] = data
            // 写磁盘只需 Data，不再共享 NSImage 实例
            writeDisk(host: host, data: data)
            return NSImage(data: data)
        }
        return nil
    }

    /// fetchRemote 返回 PNG-encoded Data：在 detached task 内一次性把网络数据 normalize
    /// 成 PNG（用 NSBitmapImageRep 转码），后续 cache/磁盘/UI 三个消费方都基于这份
    /// immutable Data 各自构造独立 NSImage，杜绝跨线程共享 NSImage 实例。
    ///
    /// 多源回退顺序（按"命中率 × 速度"权衡）：
    /// 1. host 直连 `/favicon.ico` —— 最快，约 50% 站点命中
    /// 2. 根域直连 `/favicon.ico` —— 覆盖 SPA 子域：docs.feishu.cn 没有但 feishu.cn 有
    /// 3. 拉 HTML 头部解析 `<link rel="icon">` —— 覆盖飞书/Notion/各种 SaaS 把 favicon
    ///    放在 CDN 的场景；其他应用能显示的真正信源就是这一层
    /// 4. Google s2 服务 —— 大陆走 t2.gstatic.com 重定向，可达性看运气，作为最后兜底
    private nonisolated static func fetchRemote(host: String) async -> Data? {
        var triedURLs = Set<String>()

        func tryURL(_ urlString: String) async -> Data? {
            guard !triedURLs.contains(urlString), let url = URL(string: urlString) else { return nil }
            triedURLs.insert(urlString)
            return await downloadAndNormalize(url: url)
        }

        // 第 1 源：host 直连
        if let data = await tryURL("https://\(host)/favicon.ico") { return data }

        // 第 2 源：根域回退（处理 docs.feishu.cn / app.notion.so 等 SPA 子域）
        if let root = rootDomain(of: host), root != host {
            if let data = await tryURL("https://\(root)/favicon.ico") { return data }
            if let data = await tryURL("https://www.\(root)/favicon.ico") { return data }
        }

        // 第 3 源：解析 HTML 的 <link rel="icon">。优先用原始 host（保留子域语义，
        // 比如某些 SaaS 不同子域用不同品牌色 favicon），失败再退到根域 HTML。
        for htmlHost in [host, rootDomain(of: host)].compactMap({ $0 }) where !triedURLs.contains("html:\(htmlHost)") {
            triedURLs.insert("html:\(htmlHost)")
            if let iconHref = await fetchIconFromHTML(host: htmlHost),
               let data = await tryURL(iconHref) {
                return data
            }
        }

        // 第 4 源：Google s2 兜底
        if let data = await tryURL("https://www.google.com/s2/favicons?domain=\(host)&sz=128") {
            return data
        }

        return nil
    }

    /// 下载单个 URL → 校验是真实图片 → normalize 成 PNG Data。
    /// 抽出独立函数让各源共用，避免 fetchRemote 主流程被 NSImage/NSBitmapImageRep
    /// 校验码淹没（之前所有源都重复一遍 校验+转 PNG 的样板）。
    private nonisolated static func downloadAndNormalize(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            // 校验是真实图片且非 1×1 透明占位：本地 NSImage 仅用于校验，校验完即丢
            guard let probe = NSImage(data: data), probe.size.width > 1 else { return nil }
            // Normalize 到 PNG：ico / svg / unknown 格式统一编码，磁盘读回来能直接构造 NSImage
            if let tiff = probe.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
            // 罕见：probe 成功但转 PNG 失败 → 兜底原始 data
            return data
        } catch {
            return nil
        }
    }

    /// 拉 HTML head 部分，提取 `<link rel="...icon...">` 的 href。
    /// 使用 `Range: bytes=0-65535` 限制下载量（绝大多数站点 head 在前 64KB 内），
    /// 但有些 CDN 会忽略 Range 头返回完整 HTML —— 4s 超时是兜底安全网。
    private nonisolated static func fetchIconFromHTML(host: String) async -> String? {
        guard let url = URL(string: "https://\(host)/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // 部分站点根据 UA 切首页（移动版/PC 版），用通用 Safari UA 拿到完整 HTML
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard let html = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else { return nil }

            // 解析候选：rel 必须包含 icon 字样；优先级 apple-touch-icon > icon > shortcut icon
            // （apple-touch-icon 通常是高分辨率 PNG，最适合预览面板的 64×64 显示尺寸）
            let candidates = parseIconLinks(in: html)
            guard let best = chooseBestIcon(candidates) else { return nil }

            // resolve 相对路径到完整 URL
            return URL(string: best, relativeTo: url)?.absoluteString
        } catch {
            return nil
        }
    }

    /// 解析 HTML 里所有 `<link rel="...icon..." href="...">` 标签。
    /// 用 NSRegularExpression 比 swift-html-parser 类的第三方库更轻量，
    /// favicon meta 标签结构简单稳定，正则覆盖足够。
    private nonisolated static func parseIconLinks(in html: String) -> [(rel: String, href: String, sizes: String?)] {
        // 只截取 <head>...</head> 区间，避免扫到 body 里的伪 link
        let headRange: Range<String.Index>
        if let openTag = html.range(of: "<head", options: .caseInsensitive),
           let closeTag = html.range(of: "</head>", options: .caseInsensitive, range: openTag.upperBound..<html.endIndex) {
            headRange = openTag.lowerBound..<closeTag.upperBound
        } else {
            // 没有 </head>（不完整 HTML） → 退而求其次扫描全部
            headRange = html.startIndex..<html.endIndex
        }
        let head = String(html[headRange])

        guard let linkRegex = try? NSRegularExpression(
            pattern: "<link[^>]*?>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsHead = head as NSString
        let matches = linkRegex.matches(in: head, range: NSRange(location: 0, length: nsHead.length))

        var results: [(String, String, String?)] = []
        for match in matches {
            let tag = nsHead.substring(with: match.range)
            guard let rel = extractAttribute(name: "rel", in: tag)?.lowercased(),
                  rel.contains("icon"),
                  let href = extractAttribute(name: "href", in: tag),
                  !href.isEmpty,
                  // 排除 data:image/svg+xml 之类的内联 SVG —— 通常是 1×1 灰度占位，
                  // NSImage 拿到也是无意义图标
                  !href.hasPrefix("data:") else { continue }
            let sizes = extractAttribute(name: "sizes", in: tag)
            results.append((rel, href, sizes))
        }
        return results
    }

    /// 在候选里挑最优 icon：apple-touch-icon（高分辨率 PNG）> 大 sizes 的 icon > 小 icon > shortcut icon。
    /// 这套优先级是 Safari 自己也用的——预览面板 64pt @2x = 128px，apple-touch-icon
    /// 默认 180px 完全够，且通常是 PNG 比 ICO 渲染干净。
    private nonisolated static func chooseBestIcon(_ candidates: [(rel: String, href: String, sizes: String?)]) -> String? {
        guard !candidates.isEmpty else { return nil }

        func score(_ candidate: (rel: String, href: String, sizes: String?)) -> Int {
            var s = 0
            if candidate.rel.contains("apple-touch-icon") { s += 100 }
            if candidate.rel == "icon" || candidate.rel.contains(" icon") || candidate.rel.hasSuffix("icon") { s += 50 }
            if candidate.rel.contains("shortcut") { s += 10 }
            // sizes 包含明确像素数（如 "192x192"）的优先
            if let sizes = candidate.sizes, sizes.contains("x") {
                let dims = sizes.lowercased().split(separator: "x")
                if let w = dims.first.flatMap({ Int($0) }) {
                    s += min(w, 512) / 8  // 上限避免 1024x1024 的 icon 拖垮决分
                }
            }
            return s
        }

        return candidates.max(by: { score($0) < score($1) })?.href
    }

    private nonisolated static func extractAttribute(name: String, in tag: String) -> String? {
        // 匹配 name="value" 或 name='value'，name 后允许空格
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
            options: .caseInsensitive
        ) else { return nil }
        let nsTag = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: nsTag.length)),
              match.numberOfRanges >= 2 else { return nil }
        return nsTag.substring(with: match.range(at: 1))
    }

    /// 提取 host 的根域（去掉 www / 子域）。
    /// 简化版：把 host 切成 labels，保留最后两段；不处理 .co.uk / .com.cn 等多级 TLD
    /// （会把 example.com.cn 错切成 com.cn，但 favicon 仍可能在该域命中——这种情况
    /// 极少出现在剪贴板里）。返回 nil 表示传入的就是单段（如 localhost）。
    private nonisolated static func rootDomain(of host: String) -> String? {
        let labels = host.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        // 已经是两段（example.com），返回自身让上层与原 host 比较后跳过
        if labels.count == 2 { return host }
        // www 子域：去 www 后剩 2+ 段，递归调用一次
        if labels.first == "www" {
            return labels.dropFirst().joined(separator: ".")
        }
        // 普通子域 → 取最后两段
        return labels.suffix(2).joined(separator: ".")
    }

    private func diskFile(for host: String) -> URL {
        // host 可能包含 ":" 之类字符（IPv6/带端口），替换成安全字符
        let safe = host.replacingOccurrences(of: ":", with: "_")
        return Self.diskDir.appendingPathComponent(safe).appendingPathExtension("png")
    }

    private func readDisk(host: String) -> Data? {
        let file = diskFile(for: host)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path),
              let attrs = try? fm.attributesOfItem(atPath: file.path),
              let modDate = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modDate) < Self.diskTTL,
              let data = try? Data(contentsOf: file) else {
            return nil
        }
        return data
    }

    private nonisolated func writeDisk(host: String, data: Data) {
        // 写磁盘走 detached：避免阻塞 actor 队列。Data 是值类型 Sendable，跨线程安全。
        let file = Self.diskDir.appendingPathComponent(
            host.replacingOccurrences(of: ":", with: "_")
        ).appendingPathExtension("png")
        Task.detached(priority: .utility) {
            try? data.write(to: file)
        }
    }
}

/// URL → 页面 title 的 in-memory 缓存。
///
/// 为什么 title 不像 favicon 一样磁盘缓存：
/// - title 易变（文档改名、CMS 后台编辑），磁盘缓存会让用户长期看到旧标题，比"重启失效"更误导
/// - title 是 per-URL 级（同一 host 不同 path 不同 title），缓存粒度比 favicon 细一个量级
/// - 用户对预览 title 的容忍度高于 favicon：标题缺失可以接受，标题错了反而 confusing
///
/// 拉的是用户那条具体 URL 的 HTML head，提取 `<title>` 和 `<meta property="og:title">`、
/// `<meta name="twitter:title">`，优先级 og:title > twitter:title > <title>（og 是社交分享专门
/// 优化过的版本，通常更精炼）。
private actor URLMetadataCache {
    struct Snapshot: Sendable, Equatable {
        let title: String?
    }
    static let empty = Snapshot(title: nil)
    static let shared = URLMetadataCache()

    private var cache: [String: Snapshot] = [:]
    private var pending: [String: Task<Snapshot, Never>] = [:]
    /// in-memory 上限：launcher 列表分页 50 条，预留 4× 给最近浏览路径
    private let maxEntries = 200
    private var lru: [String] = []

    func metadata(for urlString: String) async -> Snapshot {
        if let cached = cache[urlString] {
            touch(urlString)
            return cached
        }
        if let task = pending[urlString] { return await task.value }

        let task = Task<Snapshot, Never> {
            await Self.fetch(urlString: urlString)
        }
        pending[urlString] = task
        let result = await task.value
        pending[urlString] = nil
        store(urlString, snapshot: result)
        return result
    }

    private func store(_ key: String, snapshot: Snapshot) {
        if cache[key] == nil, cache.count >= maxEntries, let evict = lru.first {
            cache.removeValue(forKey: evict)
            lru.removeFirst()
        }
        cache[key] = snapshot
        touch(key)
    }

    private func touch(_ key: String) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private nonisolated static func fetch(urlString: String) async -> Snapshot {
        guard let url = URL(string: urlString) else { return Snapshot(title: nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        // 限制下载量：HTML head 在前 64KB 内的概率 >95%，部分 CDN 忽略 Range 也有 4s 兜底
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        // 部分站点按 UA 切版本（移动版 vs PC 版），用通用 Safari UA 保证拿到完整 meta
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return Snapshot(title: nil)
            }
            guard let html = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1) else {
                return Snapshot(title: nil)
            }
            return Snapshot(title: extractTitle(from: html))
        } catch {
            return Snapshot(title: nil)
        }
    }

    /// 提取 title 优先级：og:title > twitter:title > <title>。
    /// og:title 是开源协议（OpenGraph），所有现代 CMS / SaaS 都在服务端注入 —— 这是
    /// 飞书/Notion/GitHub 等 SPA 的 title 能被其他应用拿到的真正信源（HTML 实际 <title>
    /// 在 SPA 里通常是 client-side 渲染后才填，单次拉 HTML 拿不到）。
    private nonisolated static func extractTitle(from html: String) -> String? {
        // 截 head 范围（如果有），避免扫到 body 里的 og 标签碎片
        let scope: String
        if let openTag = html.range(of: "<head", options: .caseInsensitive),
           let closeTag = html.range(of: "</head>", options: .caseInsensitive, range: openTag.upperBound..<html.endIndex) {
            scope = String(html[openTag.lowerBound..<closeTag.upperBound])
        } else {
            scope = html
        }

        // 1. og:title
        if let og = extractMetaContent(in: scope, property: "og:title"), !og.isEmpty {
            return decodeHTMLEntities(og)
        }
        // 2. twitter:title
        if let tw = extractMetaContent(in: scope, name: "twitter:title"), !tw.isEmpty {
            return decodeHTMLEntities(tw)
        }
        // 3. <title>
        if let titleRegex = try? NSRegularExpression(
            pattern: "<title[^>]*>([\\s\\S]*?)</title>",
            options: .caseInsensitive
        ) {
            let nsScope = scope as NSString
            if let match = titleRegex.firstMatch(in: scope, range: NSRange(location: 0, length: nsScope.length)),
               match.numberOfRanges >= 2 {
                let raw = nsScope.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty { return decodeHTMLEntities(raw) }
            }
        }
        return nil
    }

    /// 匹配 `<meta property="og:title" content="...">` 或 `<meta name="..." content="...">`，
    /// 也允许 property/content 颠倒顺序。
    private nonisolated static func extractMetaContent(in html: String, property: String? = nil, name: String? = nil) -> String? {
        let attrName: String
        let attrValue: String
        if let property {
            attrName = "property"
            attrValue = property
        } else if let name {
            attrName = "name"
            attrValue = name
        } else { return nil }

        // 两种 attr 顺序都要匹配：property 在前 content 在后，或反之
        let patterns = [
            "<meta\\s[^>]*\\b\(attrName)\\s*=\\s*[\"']\(attrValue)[\"'][^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>",
            "<meta\\s[^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*\\b\(attrName)\\s*=\\s*[\"']\(attrValue)[\"'][^>]*>",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let nsHTML = html as NSString
            if let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
               match.numberOfRanges >= 2 {
                return nsHTML.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    /// 把常见 HTML 实体（&amp; &lt; &gt; &quot; &#39; &nbsp;）还原。
    /// 用 NSAttributedString 解码完整 HTML 太重（会启动 WebKit），实体替换轻量足够。
    private nonisolated static func decodeHTMLEntities(_ s: String) -> String {
        var out = s
        let map: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#x27;", "'"),
        ]
        for (entity, char) in map {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}

private struct FaviconView: View {
    let host: String?
    @State private var image: NSImage?
    @State private var loadFinished = false

    var body: some View {
        ZStack {
            // 三态：① 还在拉取 → globe 占位（不知道结果，不画字母圈）
            //       ② 拉到 favicon → 显示图标
            //       ③ 拉取失败 / 没 host → 字母圈兜底（host 首字母 + hash 色）
            if let image {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else if loadFinished, let host, !host.isEmpty {
                FaviconLetterMark(host: host)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                Image(systemName: "globe")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
        .task(id: host ?? "") {
            image = nil
            loadFinished = false
            guard let host, !host.isEmpty else {
                loadFinished = true
                return
            }
            let requestedHost = host
            let fetched = await FaviconCache.shared.icon(for: requestedHost)
            // 快速切 URL 时旧 host 的网络响应可能晚到，必须验证当前还在显示同一 host。
            // 否则会把上一个站点 favicon 覆盖到新条目上。
            guard !Task.isCancelled, requestedHost == host else { return }
            image = fetched
            loadFinished = true
        }
    }
}

/// favicon 拿不到时的兜底视觉：host 首字母 + 基于 host hash 的稳定背景色。
/// 同一 host 永远是同一种颜色（hash 决定），让用户在剪贴板历史里还能凭"颜色块"
/// 二次识别站点（即使叫不出名字也能看出"那一抹紫色的就是我之前看的那条"）。
///
/// 颜色生成不用 SwiftUI 默认 `.background(Color.red)` 这种饱和色——
/// 用 HSL 固定 saturation/brightness、只变 hue，保证所有字母圈视觉权重一致，
/// 不会让某个字母圈意外抢夺注意力。
private struct FaviconLetterMark: View {
    let host: String

    private var letter: String {
        // 用 host 第一段（去掉 www）的首字母。
        // "docs.feishu.cn" → "D"（不是 "d"，preview 视觉一致要大写）
        // "www.github.com" → "G"
        // "localhost" → "L"
        let lower = host.lowercased()
        let parts = lower.split(separator: ".")
        let firstMeaningful = parts.first(where: { $0 != "www" }) ?? parts.first ?? Substring(host)
        return String(firstMeaningful.first ?? Character("?")).uppercased()
    }

    private var backgroundColor: Color {
        // host → 稳定 hash → HSL hue。
        // 不用 Hasher（Hasher 每次进程启动种子不同 → 同一 host 颜色会变），
        // 改用 FNV-1a 的简化版本，保证跨启动一致。
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in host.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        let hue = Double(hash % 360) / 360.0
        // saturation 0.55 / brightness 0.62 是经验值：饱和度足以区分相邻 hue，
        // 又不至于刺眼；白字在上面对比度也够。
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }

    var body: some View {
        backgroundColor
            .overlay(
                Text(letter)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            )
    }
}

private struct URLPreviewView: View {
    let urlString: String
    let searchQuery: String
    @EnvironmentObject var vm: ClipboardViewModel
    /// 从 URLMetadataCache 异步拉取的页面标题；nil 表示尚未加载或拉不到。
    /// 加载完成后会显示在 header 顶部，host 退到次行——同其他应用对齐。
    @State private var pageTitle: String?

    private var url: URL? { URL(string: urlString) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                fullURLBlock
                if let url, !queryItems(for: url).isEmpty {
                    queryBlock(items: queryItems(for: url))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
        .task(id: urlString) {
            pageTitle = nil
            let requested = urlString
            let snapshot = await URLMetadataCache.shared.metadata(for: requested)
            // 快速切条目时旧 URL 的响应可能晚到 → guard 当前仍在显示同一 URL
            guard !Task.isCancelled, requested == urlString else { return }
            pageTitle = snapshot.title
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            FaviconView(host: url?.host)
                .frame(width: 64, height: 64)

            // title 取到 → 大字 title + 次行 host[+path]；
            // 没取到 → 退化成原来的"host 在顶、path 在副"——首屏加载完成前的稳态。
            VStack(alignment: .leading, spacing: 4) {
                if let pageTitle, !pageTitle.isEmpty {
                    Text(pageTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)

                    Text(hostWithPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(ClipinInk.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(url?.host ?? urlString)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    if let subtitle = pathSubtitle {
                        Text(subtitle)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ClipinInk.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Open")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(Color.accentColor)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open in default browser")
            }
        }
    }

    /// 有 title 时副行用 `host + path` 显示完整位置感
    private var hostWithPath: String {
        guard let url else { return urlString }
        let host = url.host ?? ""
        if !url.path.isEmpty, url.path != "/" {
            return host + url.path
        }
        return host
    }

    private var pathSubtitle: String? {
        guard let url else { return nil }
        if !url.path.isEmpty, url.path != "/" { return url.path }
        return nil
    }

    private var fullURLBlock: some View {
        urlInfoBlock(title: "Full URL", systemImage: "link", trailing: {
            // 仅当存在已知 tracking 参数时显示"Copy clean URL"，避免在干净 URL 上误导。
            if let cleaned = cleanedURLString, cleaned != urlString {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(cleaned, forType: .string)
                    vm.showNotice(NSLocalizedString("Clean URL copied", comment: ""))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "scissors")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Clean copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(ClipinInk.secondary)
                    .clipinChromeGlass(in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Copy URL without tracking parameters (utm_*, fbclid, gclid, mc_*)")
            }
        }) {
            SelectableTextPreview(
                text: urlString,
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                searchQuery: searchQuery,
                vm: vm
            )
            .frame(minHeight: 44, maxHeight: 92)
        }
    }

    /// 已知 tracking 参数前缀：剥掉这些保留语义、不破坏目标页面正常访问。
    /// 来源：UTM 协议 + 社交平台 click ID + 邮件营销主流前缀。
    private static let trackingParamPrefixes: [String] = [
        "utm_", "mc_", "ga_", "_hs", "vero_", "trk_",
    ]
    private static let trackingParamExacts: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "yclid",
        "igshid", "ref_src", "ref_url", "twclid", "li_fat_id",
        "spm", "scm",
    ]

    private var cleanedURLString: String? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return nil }
        let filtered = items.filter { item in
            let name = item.name.lowercased()
            if Self.trackingParamExacts.contains(name) { return false }
            if Self.trackingParamPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
            return true
        }
        guard filtered.count != items.count else { return nil }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.url?.absoluteString
    }

    private func queryItems(for url: URL) -> [(String, String)] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return [] }
        return items.map { ($0.name, $0.value ?? "") }
    }

    private func queryBlock(items: [(String, String)]) -> some View {
        urlInfoBlock(title: "Query parameters", systemImage: "questionmark.app") {
            VStack(spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, pair in
                    HStack(alignment: .top, spacing: 12) {
                        Text(pair.0)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(ClipinInk.secondary)
                            .frame(width: 96, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                        Text(pair.1)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ClipinInk.primary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func urlInfoBlock<Content: View, Trailing: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Spacer(minLength: 6)
                trailing()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
