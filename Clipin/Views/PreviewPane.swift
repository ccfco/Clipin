import SwiftUI
import AppKit
import ImageIO
import NaturalLanguage
import UniformTypeIdentifiers

/// 右侧预览面板。
///
/// 与导航解耦的关键：本视图**不观察** ClipboardViewModel（不用 @EnvironmentObject/@ObservedObject），
/// 只持 `let vm` 引用调用动作；所有响应式状态由 MainPanel（它观察 vm）以**值**注入。
/// 配合 MainPanel 处的 `.equatable()`，导航连按时这些值不变（selectedItem 被去抖压住、revision 不变）
/// → 整棵预览子树跳过重渲染，按键路径不被预览渲染占住（实测预览渲染是 ↑↓ 卡顿的确凿主因）。
struct PreviewPane: View, Equatable {
    let item: ClipItem?
    var searchQuery: String = ""
    let sceneState: ClipinSceneState
    /// 见 ClipboardViewModel.selectedItemRevision：被预览条目变化的精确判等信号。
    let itemRevision: Int
    let editingItemID: String?
    let representationUTIs: [String]
    let hasSelection: Bool
    let fileAttachmentIndex: Int
    /// 内容编辑草稿（独立 ObservableObject，ContentEditorView 自行 @ObservedObject 订阅）。
    let editingDraft: EditingDraft
    /// 仅用于调用动作（commit/cancel 编辑、showNotice、网络加载标记等），不观察。
    let vm: ClipboardViewModel

    /// 判等只比「会影响预览渲染的值」，忽略 item（其变化由 itemRevision 捕获）、vm（同一实例）、
    /// editingDraft（同一实例）。导航连按时全部相等 → SwiftUI 跳过 body。
    nonisolated static func == (lhs: PreviewPane, rhs: PreviewPane) -> Bool {
        lhs.itemRevision == rhs.itemRevision &&
        lhs.searchQuery == rhs.searchQuery &&
        lhs.sceneState == rhs.sceneState &&
        lhs.editingItemID == rhs.editingItemID &&
        lhs.representationUTIs == rhs.representationUTIs &&
        lhs.hasSelection == rhs.hasSelection &&
        lhs.fileAttachmentIndex == rhs.fileAttachmentIndex
    }

    /// metadata 预热触发器：item 切换时 `.task` 异步把 dimensions/fileSize/appIcon 写进
    /// PreviewMetadataCache，完成后 revision +1 强制 body 重建，此时 cached* 同步命中显示。
    /// 这是"body 永远不做主线程同步 IO"的关键桥；首次未命中那一瞬间相关 badge 暂时不显示，
    /// 比同步阻塞主线程更顺。
    @State private var metadataRevision: Int = 0

    var body: some View {
        Group {
            if let item {
                if editingItemID == item.id {
                    contentStage {
                        ContentEditorView(
                            draft: editingDraft,
                            onSave: { vm.commitEditContent() },
                            onCancel: { vm.cancelEditContent() }
                        )
                    }
                } else {
                    contentStage(for: item)
                }
            } else if hasSelection {
                // 已有选中行、但 payload 尚未落定（仅首帧 / 读失败后会短暂命中——正常导航中
                // displayedItem 滞后停在上一落定项，不会落到这里）。保留布局留白即可，禁止转圈圈：
                // 加载指示全 app 统一只走顶部流光（且仅真异步源点亮），本地 getItem 瞬时无需任何指示。
                contentStage {
                    Color.clear
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
        // 所有 clip 类型统一走 PreviewFadeFooterContainer:image/file/url 走 `.managed`
        // (容器自带 ScrollView),text 走 `.external`(SelectableTextPreview 自管 NSScrollView)。
        // contentStage 不再需要按 clipType 分支套外层 safeAreaInset / mask——架构上 4 类
        // preview body 同源,fade/footer 单点在容器内收口。
        contentStage {
            content(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func contentStage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // 预览是阅读区(非选中行),内容左右上内距用 groupGap 留出阅读呼吸位。
        // 下方留 floatingFooterBand 高的避让带给底栏命令胶囊;metadata 脚注由 PreviewFadeFooterContainer
        // 内的 Spacer 顶到避让带顶沿,正好落在命令胶囊上方(短内容也不上浮、不离命令太远)。
        content()
            .padding(.horizontal, ClipinChrome.groupGap)
            .padding(.top, ClipinChrome.groupGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.bottom, ClipinChrome.floatingFooterBand)
    }

    @ViewBuilder
    private func content(for item: ClipItem) -> some View {
        switch item.clipType {
        case .text:
            // text 与 image/file/url 同样走 PreviewFadeFooterContainer 主干,fade + footer
            // 与其它三类一致。`.external` 模式因为 SelectableTextPreview 内嵌 NSScrollView
            // 自管滚动,容器不再叠一层 ScrollView——避免双层滚动。
            PreviewFadeFooterContainer(
                footerEntries: footerEntries(for: item),
                scrollStrategy: .external
            ) {
                if let color = detectColorForPreview(in: item.content) {
                    ColorSwatchPreview(vm: vm, color: color, originalText: item.content)
                        .frame(maxWidth: 480, alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextPreviewBody(
                        text: item.content,
                        font: previewTextFont(),
                        searchQuery: searchQuery,
                        vm: vm
                    )
                    .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
                }
            }

        case .url:
            URLPreviewView(
                urlString: item.content,
                searchQuery: searchQuery,
                footerEntries: footerEntries(for: item),
                vm: vm
            )

        case .image:
            // 不挂 `.id(item.id)`：整棵子树（ScrollView + 渐隐遮罩 + footer）按 item 全量重建是
            // 一次 ~20ms 主线程开销，停留后又按 ↑↓ 时偶尔撞上这次重建 → 偶发不跟手。去掉后 SwiftUI
            // diff 复用容器、只换内容，渲染更便宜。唯一持有异步 @State 的图片叶子按 path 单独 .id 重置
            // （见 ImagePreviewBody），既防错图闪、又不牵连整棵子树。
            ImagePreviewBody(
                item: item,
                searchQuery: searchQuery,
                vm: vm,
                footerEntries: footerEntries(for: item)
            )

        case .file:
            // 同上：fileIcons 虽然每次 .task 都会全量覆盖，但 .id 是更稳的防御，
            // 保证未来再加 @State 时不会无声地跨 item 携带状态。
            FilePreviewBody(
                item: item,
                searchQuery: searchQuery,
                vm: vm,
                fileAttachmentIndex: fileAttachmentIndex,
                footerEntries: footerEntries(for: item)
            )
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
        let utis = representationUTIs
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

    struct PreviewBadgeItem: Identifiable {
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

    struct PreviewRailEntry: Identifiable {
        let item: PreviewBadgeItem
        var id: String { item.id }
    }

    private func placeholder(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: ClipinChrome.gap) {
            ZStack {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
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
        /// 仅传 SelectableTextPreview 做动作（weak 持有），不观察。
        let vm: ClipboardViewModel

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
            // `.fragmentsAllowed` 和 `.topLevelDictionaryAssumed` 互斥，同时设置 NSJSONSerialization
            // 抛 NSInvalidArgumentException（"cannot be set at the same time"）。
            // 上面 guard 已经守住 first == { || [，顶层一定是 dict/array，不需要任何特殊 options。
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: []),
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

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                // 仅当检测到 JSON 时才显示 toggle，避免对普通文本造成视觉噪声
                if isJSON {
                    HStack(spacing: ClipinChrome.gap) {
                        Label("JSON", systemImage: "curlybraces")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ClipinInk.secondary)
                        Spacer(minLength: 6)
                        Button {
                            renderMode = renderMode == .auto ? .raw : .auto
                        } label: {
                            HStack(spacing: ClipinChrome.gap) {
                                Image(systemName: renderMode == .auto ? "text.alignleft" : "text.justify.leading")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(renderMode == .auto ? "Show raw" : "Pretty")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, ClipinChrome.gap)
                            .padding(.vertical, ClipinChrome.gap)
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

/// 内容编辑器，独立成 view 并以 @ObservedObject 订阅 EditingDraft——
/// 打字时只有它自己重渲染，不波及左侧列表。
