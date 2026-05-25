import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewBody: View {
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
            VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                header(primaryPath: primaryPath, primaryURL: primaryURL, paths: allPaths)

                if singleImageFile {
                    AsyncPreviewImage(path: primaryPath, maxHeight: 360) {
                        pathFallback(allPaths: allPaths)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: ClipinChrome.cornerControl, style: .continuous))
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
    private func multiFileList(paths: [String]) -> some View {
        let shown = Array(paths.prefix(maxRows))
        let overflow = paths.count - shown.count
        // 文件行图标边长。命名后既驱动图标 frame，又驱动 "+N more" 的对齐缩进。
        let iconSize: CGFloat = 18

        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Label("Selection", systemImage: "square.stack.3d.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)

            VStack(alignment: .leading, spacing: ClipinChrome.gap) {
                ForEach(shown, id: \.self) { path in
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

    private func fileHeaderSubtitle(paths: [String], primaryURL: URL) -> String {
        let directory = primaryURL.deletingLastPathComponent().path
        guard paths.count > 1 else { return directory }
        return "\(FileClipboardContent.summaryLabel(for: paths.joined(separator: "\n"))) • \(directory)"
    }
}

/// 图片预览主体：图片 + OCR 文本在可滚动区，元数据底栏固定在其下方常驻可见。
