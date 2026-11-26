import AppKit
import SwiftUI

struct SelectableTextPreview: NSViewRepresentable {
    let text: String
    let font: NSFont
    var searchQuery: String = ""
    weak var vm: ClipboardViewModel?

    /// NSDataDetector 创建并非零成本（底层是 NLP regex 状态机）。
    /// 文档明确表示 thread-safe，可以全局静态复用。
    static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var lastTextHash: Int = 0
        var lastQueryHash: Int = 0
        var lastFontDescriptor: NSFontDescriptor?
        /// 文本不变时复用上次链接扫描结果；query/font 变化无需重扫
        var detectedLinks: [(NSRange, URL)] = []
        /// 文本不变时复用已解析的本地路径链接；由后台异步校验后回填
        var detectedPaths: [(NSRange, URL)] = []
        var pathResolutionTask: Task<Void, Never>?
        var hasInitialized = false
        weak var vm: ClipboardViewModel?

        deinit {
            pathResolutionTask?.cancel()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let direct = link as? URL {
                url = direct
            } else if let str = link as? String {
                url = URL(string: str)
            } else {
                url = nil
            }
            guard let url, url.isFileURL else {
                // 非 file:// 链接（http/https 等）交回系统默认处理
                return false
            }
            MainActor.assumeIsolated {
                if let vm {
                    vm.openLocalURL(url)
                } else if LocalPathDetector.isTrueDirectory(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            return true
        }
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
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.vm = vm

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

        // 链接检测 + 本地路径提取：text 变了才重扫，仅 query 变复用上次结果
        var uncachedPathCandidates: [InlinePathCandidate] = []
        if textChanged {
            coord.pathResolutionTask?.cancel()
            coord.pathResolutionTask = nil

            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            var links: [(NSRange, URL)] = []
            Self.linkDetector?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                if let match, let url = match.url {
                    links.append((match.range, url))
                }
            }

            // 仅排除原文自带协议头（如 https:// / file:// / mailto:）的 URL，
            // 避免 NSDataDetector 把 `/Users/foo/project.io` 误拆成 `http://project.io` 后屏蔽本地路径。
            let explicitSchemeRanges = links.compactMap { range, _ -> NSRange? in
                let matched = nsText.substring(with: range).lowercased()
                return (matched.contains("://") || matched.hasPrefix("mailto:")) ? range : nil
            }

            let candidates = LocalPathDetector.extractInlineCandidates(
                in: text,
                excluding: explicitSchemeRanges
            )
            var cachedResolvedPaths: [(NSRange, URL)] = []
            for candidate in candidates {
                if PreviewMetadataCache.shared.hasCachedLocalPathProbe(for: candidate.rawPath) {
                    if let hit = PreviewMetadataCache.shared.cachedLocalPath(for: candidate.rawPath) {
                        cachedResolvedPaths.append((candidate.range, hit.url))
                    }
                } else {
                    uncachedPathCandidates.append(candidate)
                }
            }
            coord.detectedPaths = cachedResolvedPaths
            coord.detectedLinks = links.filter { linkRange, _ in
                !cachedResolvedPaths.contains { NSIntersectionRange($0.0, linkRange).length > 0 }
            }
        }

        for (range, url) in coord.detectedLinks {
            attributed.addAttribute(.link, value: url, range: range)
        }
        for (range, url) in coord.detectedPaths {
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

        if textChanged, !uncachedPathCandidates.isEmpty {
            coord.pathResolutionTask = Task { @MainActor [weak textView, weak coord] in
                let resolved = await PreviewMetadataCache.shared.loadInlinePaths(for: uncachedPathCandidates)
                guard !Task.isCancelled,
                      let coord,
                      let textView,
                      coord.lastTextHash == textHash,
                      !resolved.isEmpty else {
                    return
                }
                let newlyAdded = resolved.map { ($0.0, $0.1.url) }
                let overlappedLinks = coord.detectedLinks.filter { linkRange, _ in
                    newlyAdded.contains { NSIntersectionRange($0.0, linkRange).length > 0 }
                }
                if !overlappedLinks.isEmpty {
                    coord.detectedLinks.removeAll { linkRange, _ in
                        newlyAdded.contains { NSIntersectionRange($0.0, linkRange).length > 0 }
                    }
                }
                coord.detectedPaths.append(contentsOf: newlyAdded)
                guard let storage = textView.textStorage else { return }
                let storageLength = storage.length
                storage.beginEditing()
                for (linkRange, _) in overlappedLinks where NSMaxRange(linkRange) <= storageLength {
                    storage.removeAttribute(.link, range: linkRange)
                }
                for (range, url) in newlyAdded where NSMaxRange(range) <= storageLength {
                    storage.addAttribute(.link, value: url, range: range)
                }
                storage.endEditing()
            }
        }
    }
}

