import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewBody: View {
    let item: ClipItem
    let searchQuery: String
    /// 必须 @ObservedObject:multiFileStack 读 vm.fileAttachmentPreviewIndex,
    /// 改为 @ObservedObject 后 SwiftUI 才会订阅 @Published 变化重渲染视图。
    /// 原写法 `let vm: ClipboardViewModel` 仅传引用不订阅,导致 ←→ / 鼠标点击切换栈无响应。
    @ObservedObject var vm: ClipboardViewModel
    /// 元数据底栏徽章数据;由 PreviewFadeFooterContainer 统一渲染。
    let footerEntries: [PreviewPane.PreviewRailEntry]

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

    private var attachmentPaths: [String] {
        guard let raw = item.attachmentPaths,
              let data = raw.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    var body: some View {
        let allPaths = paths
        let primaryPath = allPaths.first ?? item.content
        let primaryURL = URL(fileURLWithPath: primaryPath)

        PreviewFadeFooterContainer(footerEntries: footerEntries) {
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                if allPaths.count > 1 {
                    // 多文件 → Raycast 风格叠放卡作为视觉主角:组语义 + 内容预览合一。
                    // 紧随的 header 退化为纯文本(name + count + path),不再画小 icon——
                    // 视觉权重已由叠放卡承担,小 icon 会和叠放冲突。
                    // 标题与列表同步当前栈顶 index:用户切到 file 2 时,标题和列表的高亮同步切换,
                    // 三处视觉信号(栈/标题/列表)指向同一个文件,避免"卡是 2、标题写 1"语义割裂。
                    let clampedIndex = min(max(0, vm.fileAttachmentPreviewIndex), allPaths.count - 1)
                    let currentPath = allPaths[clampedIndex]
                    let currentURL = URL(fileURLWithPath: currentPath)
                    multiFileStack(paths: allPaths)
                    multiFileTextHeader(currentPath: currentPath, currentURL: currentURL, paths: allPaths)
                    multiFileList(paths: allPaths, currentIndex: clampedIndex)
                } else {
                    // 单文件:沿用原 header + 大图/路径回退布局
                    header(primaryPath: primaryPath, primaryURL: primaryURL, paths: allPaths)
                    let imagePreviewPaths = resolvedImagePreviewPaths(originalPaths: allPaths)
                    if !imagePreviewPaths.isEmpty {
                        imagePreview(paths: imagePreviewPaths)
                    } else {
                        pathFallback(allPaths: allPaths)
                    }
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

    @ViewBuilder
    private func imagePreview(paths: [String]) -> some View {
        let clampedIndex = min(vm.fileAttachmentPreviewIndex, paths.count - 1)
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            ZStack(alignment: .bottomTrailing) {
                AsyncPreviewImage(path: paths[clampedIndex], maxHeight: 360) {
                    pathFallback(allPaths: [paths[clampedIndex]])
                }
                    // 方角：用户明确要求，方便识别"这是张真实的图"而非"卡片化包装"。
                    // 与列表行图片缩略图保持一致的视觉语言。
                    .frame(maxWidth: .infinity, alignment: .leading)

                if paths.count > 1 {
                    HStack(spacing: ClipinChrome.gap) {
                        Button {
                            vm.stepFileAttachmentPreview(delta: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.plain)
                        .disabled(clampedIndex == 0)

                        Text("\(clampedIndex + 1) / \(paths.count)")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(ClipinInk.secondary)
                            .monospacedDigit()

                        Button {
                            vm.stepFileAttachmentPreview(delta: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(clampedIndex == paths.count - 1)
                    }
                    .padding(.horizontal, ClipinChrome.groupGap)
                    .padding(.vertical, ClipinChrome.gap)
                    .glassEffect(.regular, in: Capsule())
                    .padding(ClipinChrome.groupGap)
                }
            }
        }
    }

    private func icon(for path: String) -> NSImage? {
        if let cached = fileIcons[path] { return cached }
        // 第一次 body 重建时 .task 还没跑完，先查 shared cache
        return PreviewMetadataCache.shared.cachedFileIcon(at: path)
    }

    // MARK: - 多文件叠放卡(Raycast 风格)

    /// 卡片尺寸常量。180×224 让单卡足够大能看清图片内容,4:5 portrait 比例适配竖图(iPhone 截屏),
    /// 横图时由 AsyncPreviewImage 的 .fit 自动 letterbox。
    private static let stackCardWidth: CGFloat = 180
    private static let stackCardHeight: CGFloat = 224
    /// 背景卡相对前景的水平偏移与旋转角度,决定"扇形"展开的程度。
    /// 28pt + 9° 让背景卡露出约 1/3,既能看到"后面还有"又不抢前景注意力。
    private static let stackBackOffset: CGFloat = 28
    private static let stackBackRotation: Double = 9

    @ViewBuilder
    private func multiFileStack(paths: [String]) -> some View {
        let count = paths.count
        let clampedIndex = min(max(0, vm.fileAttachmentPreviewIndex), count - 1)
        // 叠放总 frame:前景卡 + 背景偏移 *2 + 旋转引入的额外宽度(估算 28pt)
        let stackWidth = Self.stackCardWidth + Self.stackBackOffset * 2 + 28
        let stackHeight = Self.stackCardHeight + 24

        // 循环 wrap 的背景卡索引:
        // - count == 2:仅露 back-right(back-left 会和 back-right 重复同一张,视觉冗余)
        // - count >= 3:双侧都 wrap,任意位置均看到前后两张,视觉强化"这是循环栈"
        let backLeftIndex: Int? = count >= 3 ? (clampedIndex - 1 + count) % count : nil
        let backRightIndex: Int? = count >= 2 ? (clampedIndex + 1) % count : nil

        VStack(spacing: ClipinChrome.gap) {
            ZStack {
                if let i = backLeftIndex {
                    stackCard(at: i, paths: paths)
                        .rotationEffect(.degrees(-Self.stackBackRotation))
                        .offset(x: -Self.stackBackOffset, y: 4)  // spacing-exempt: 叠放卡垂直微偏
                        .zIndex(0)
                }
                if let i = backRightIndex {
                    stackCard(at: i, paths: paths)
                        .rotationEffect(.degrees(Self.stackBackRotation))
                        .offset(x: Self.stackBackOffset, y: 4)  // spacing-exempt: 叠放卡垂直微偏
                        .zIndex(0)
                }
                // 前景卡:用户当前关注的文件,无旋转,zIndex=1 始终在最上层。
                // `.id(clampedIndex)` 让 SwiftUI 把每次 index 变化识别为"换了一张卡",
                // 触发 `.transition(.push)` 的插入/移除动画;`.push(from:)` 是 macOS 14+
                // 系统级 transition(NavigationStack push 同款),按方向自动滑入推出,
                // 跟随 a11y reduce motion 与 ProMotion 适配,无需自造。
                stackCard(at: clampedIndex, paths: paths)
                    .id(clampedIndex)
                    .transition(.push(from: vm.lastStepDirection >= 0 ? .trailing : .leading))
                    .zIndex(1)

                // ← → chevron 浮在两侧。循环切换后任何位置 chevron 都常亮(用户期望"按下去总有反应")。
                HStack {
                    chevron(direction: -1)
                    Spacer()
                    chevron(direction: 1)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ClipinChrome.gap)
                .zIndex(2)
            }
            .frame(width: stackWidth, height: stackHeight)
            // `Animation.smooth` 是 Apple WWDC23 起 curated 的"通用 UI 切换" spring 预设,
            // 跟随系统 a11y / ProMotion 自动适配,比自造 spring 更"系统感"。
            // 不用 ClipinMotion.feedback(0.22/0.82)——那个定位是"按钮触发反馈",太脆;
            // 切栈是"内容转场",.smooth 更契合(且与 Apple 推荐路径同源)。
            .animation(.smooth, value: clampedIndex)

            // N / Total 指示器:与前面 chevron 同源数据,告诉用户在叠放栈的哪个位置。
            Text("\(clampedIndex + 1) / \(count)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }

    private func chevron(direction: Int) -> some View {
        Button {
            vm.stepFileAttachmentPreview(delta: direction)
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.55))
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单张叠放卡:白底圆角 + soft shadow + 内容(图片或文件 icon)。
    /// 白底是 Raycast 视觉语言核心——卡是容器,内容(图/icon)被容器包裹,
    /// 与列表行"裸图片"形成层级区分(裸图=快速识别,卡=主预览)。
    @ViewBuilder
    private func stackCard(at index: Int, paths: [String]) -> some View {
        let path = paths[index]
        let resolvedImagePath = imagePathForPreview(originalPath: path, originalIndex: index)
        ZStack {
            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

            if let imgPath = resolvedImagePath {
                AsyncPreviewImage(path: imgPath, maxHeight: Self.stackCardHeight - ClipinChrome.groupGap) {
                    stackCardFallback(path: path)
                }
                .padding(ClipinChrome.gap)
            } else {
                stackCardFallback(path: path)
            }
        }
        .frame(width: Self.stackCardWidth, height: Self.stackCardHeight)
    }

    /// 非图文件 / 图片解码失败时的卡片内容:大 file icon + 居中文件名。
    @ViewBuilder
    private func stackCardFallback(path: String) -> some View {
        VStack(spacing: ClipinChrome.gap) {
            if let img = icon(for: path) {
                Image(nsImage: img)
                    .resizable()
                    .frame(width: 72, height: 72)
            } else {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 72, height: 72)
            }
            Text(FileClipboardContent.displayName(for: path))
                .font(.system(size: 11.5))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(ClipinInk.secondary)
                .padding(.horizontal, ClipinChrome.gap)
        }
    }

    /// 多文件场景的 header:纯文本(name + count + path),不再画小 icon——叠放卡已承担视觉权重。
    /// 标题显示**当前栈顶选中**文件的名,而非永远第一个——和 multiFileStack 视觉同步。
    @ViewBuilder
    private func multiFileTextHeader(currentPath: String, currentURL: URL, paths: [String]) -> some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text(FileClipboardContent.displayName(for: currentPath))
                .font(.system(size: 17, weight: .semibold))
            Text(fileHeaderSubtitle(paths: paths, primaryURL: currentURL))
                .font(.system(size: 12.5))
                .foregroundStyle(ClipinInk.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 给一个 path + 它在原 paths 数组中的位置,返回可预览的图片路径——
    /// 优先用 attachment_paths 缓存(iPhone 隔空 jpeg 落到本地缓存),其次用原 path(本地图存在),
    /// 都没有就返回 nil(由 stackCardFallback 渲染 icon)。
    private func imagePathForPreview(originalPath: String, originalIndex: Int) -> String? {
        let cached = attachmentPaths
        if cached.indices.contains(originalIndex) {
            let cachedPath = cached[originalIndex]
            if !cachedPath.isEmpty,
               FileManager.default.fileExists(atPath: cachedPath),
               isImageFile(cachedPath) {
                return cachedPath
            }
        }
        if FileManager.default.fileExists(atPath: originalPath), isImageFile(originalPath) {
            return originalPath
        }
        return nil
    }

    @ViewBuilder
    private func header(primaryPath: String, primaryURL: URL, paths: [String]) -> some View {
        HStack(spacing: ClipinChrome.groupGap) {
            ZStack {
                RoundedRectangle(cornerRadius: ClipinChrome.cornerSurface, style: .continuous)
                    .fill(Color(nsColor: .controlColor))
                if let img = icon(for: primaryPath) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 54, height: 54)
                }
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
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
    private func multiFileList(paths: [String], currentIndex: Int) -> some View {
        let shown = Array(paths.prefix(maxRows))
        let overflow = paths.count - shown.count
        // 文件行图标边长。命名后既驱动图标 frame，又驱动 "+N more" 的对齐缩进。
        let iconSize: CGFloat = 18

        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Label("Selection", systemImage: "square.stack.3d.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, path in
                    let isCurrent = index == currentIndex
                    HStack(spacing: ClipinChrome.gap) {
                        if let img = icon(for: path) {
                            Image(nsImage: img)
                                .resizable()
                                .frame(width: iconSize, height: iconSize)
                        } else {
                            RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .frame(width: iconSize, height: iconSize)
                        }
                        Text(FileClipboardContent.displayName(for: path))
                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Color.primary : ClipinInk.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 当前栈顶行加 accent 底色,与叠放卡前景同源——三处视觉(栈/标题/列表)
                    // 指向同一文件,用户切换 ←→ 时能立刻在列表里定位"我在哪"。
                    .padding(.horizontal, ClipinChrome.gap)
                    .padding(.vertical, ClipinChrome.gap)
                    .background(
                        RoundedRectangle(cornerRadius: ClipinChrome.cornerTile, style: .continuous)
                            .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                }
                if overflow > 0 {
                    Text(String(format: NSLocalizedString("+%d more", comment: ""), overflow))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ClipinInk.secondary)
                        // 缩进 = 图标宽 + 图标↔文字间距，让 "+N more" 与上方文件名左缘对齐。
                        .padding(.leading, iconSize + ClipinChrome.gap)
                        .padding(.top, ClipinChrome.gap)
                }
            }
        }
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func pathFallback(allPaths: [String]) -> some View {
        let fileListText = allPaths.isEmpty ? item.content : allPaths.joined(separator: "\n")
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
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
        .padding(ClipinChrome.groupGap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }

    private func resolvedImagePreviewPaths(originalPaths: [String]) -> [String] {
        let cached = attachmentPaths
        return originalPaths.enumerated().compactMap { index, path in
            if cached.indices.contains(index) {
                let cachedPath = cached[index]
                if !cachedPath.isEmpty,
                   FileManager.default.fileExists(atPath: cachedPath),
                   isImageFile(cachedPath) {
                    return cachedPath
                }
            }
            guard FileManager.default.fileExists(atPath: path), isImageFile(path) else { return nil }
            return path
        }
    }

    private func fileHeaderSubtitle(paths: [String], primaryURL: URL) -> String {
        let directory = primaryURL.deletingLastPathComponent().path
        guard paths.count > 1 else { return directory }
        return "\(FileClipboardContent.summaryLabel(for: paths.joined(separator: "\n"))) • \(directory)"
    }
}

/// 图片预览主体：图片 + OCR 文本在可滚动区，元数据底栏固定在其下方常驻可见。
