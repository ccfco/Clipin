import AppKit

/// file 类型写剪贴板失败时的失败原因，供调用方区分文案语义。
/// 不改 writeToClipboard 的 Bool 签名——失败原因是诊断信息，不影响主控制流，
/// 调用方在已知写失败后单独 stat 一次磁盘即可，避免侵入式 enum 返回值改造所有 6+ 调用点。
enum FilePasteFailureReason {
    /// 整组源文件都不存在（典型：iPhone 隔空剪贴板临时文件被系统清理）
    case sourceMissing
    /// 部分源文件丢失（整组校验失败但还有幸存文件）
    case partial
    /// 真正的写入被系统拒绝（权限等罕见原因）
    case writeRejected
}

/// 模拟粘贴 — 写回剪贴板 + CGEvent 模拟 Cmd+V
enum PasteService {
    /// 将 ClipItem 写回剪贴板，成功返回 true
    @discardableResult
    static func writeToClipboard(_ item: ClipItem) -> Bool {
        // 等价于"主载体 + 空辅助 reps"——所有 clipType 都走 writeAllRepresentations 单一路径。
        // 由调用方（如 performCopy）决定是否读 reps 后调 writeAllRepresentations 拿多 UTI 回放。
        return writeAllRepresentations(item, representations: [])
    }

    /// 写剪贴板的统一入口：主载体 + 辅助 reps 一起回放。
    /// - text/url：主载体是 content 字符串，reps 是 HTML/RTF/URL 等富表达
    /// - image：主载体是 imagePath 的 PNG bytes，reps 是 file-url（本地图片场景能再粘成文件）等
    /// - file：主载体是多个 file-url（独立 NSPasteboardItem），reps 是 image bytes（系统给的预览）等
    ///
    /// 不变量保护（CLAUDE.md）：所有 setData 在游离 pbItem 上先校验，
    /// 全部成功后才 clearContents+writeObjects——任一失败不擦掉用户当前系统剪贴板。
    /// 存量条目 reps 为空时自然退化为"仅主载体"，与改造前行为等价。
    @discardableResult
    static func writeAllRepresentations(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        switch item.clipType {
        case .text, .url:
            return writeTextOrURL(item, representations: representations, to: pasteboard)
        case .image:
            return writeImage(item, representations: representations, to: pasteboard)
        case .file:
            return writeFile(item, representations: representations, to: pasteboard)
        }
    }

    /// text/url：主载体是 content 字符串，reps 是富表达白名单（HTML/RTF/URL 等）。
    private static func writeTextOrURL(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard
    ) -> Bool {
        let pbItem = NSPasteboardItem()
        guard pbItem.setString(item.content, forType: .string) else { return false }
        var writtenTypes: Set<NSPasteboard.PasteboardType> = [.string]

        if item.clipType == .url {
            guard pbItem.setString(item.content, forType: .URL) else { return false }
            writtenTypes.insert(.URL)
        }

        for rep in representations {
            let type = NSPasteboard.PasteboardType(rep.uti)
            // 已写过的 type 跳过（避免 url 的 .URL 与 rep 的 public.url 重复触发必败的 setData）
            guard writtenTypes.insert(type).inserted else { continue }
            guard pbItem.setData(rep.data, forType: type) else { return false }
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
    }

    /// image：主载体同时挂 PNG + TIFF 两种 UTI（旧 Photoshop / IM apps 仅识别 TIFF，
    /// 单 PNG 会让这类消费方读不到图）；辅助 reps 中的 file-url 若指向的源文件仍在，
    /// 也挂上（让"Finder 复制本地图片"经 Clipin 历史回放仍可粘到 Finder 当文件）。
    /// 手动构造 pbItem 而不是 NSImage.writeObjects：直接控制 UTI 集合，
    /// 让辅助 reps 能挂到同一个 pbItem——多 UTI 必须挂在同一个 pbItem 上才会被消费方一起感知。
    private static func writeImage(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard
    ) -> Bool {
        guard let path = item.imagePath,
              let pngData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        let pbItem = NSPasteboardItem()
        guard pbItem.setData(pngData, forType: .png) else { return false }
        var writtenTypes: Set<NSPasteboard.PasteboardType> = [.png]

        // 补 TIFF：从 PNG bytes 通过 NSImage 转 TIFF。失败容忍——主载体 PNG 已就位，
        // 多挂一种 UTI 是为了兼容旧 TIFF-only 消费方，不应让整体写入失败。
        if let image = NSImage(data: pngData), let tiffData = image.tiffRepresentation,
           pbItem.setData(tiffData, forType: .tiff) {
            writtenTypes.insert(.tiff)
        }

        // 辅助 reps：file-url 校验源文件存在，其他 UTI 直接挂
        for rep in representations {
            let type = NSPasteboard.PasteboardType(rep.uti)
            guard writtenTypes.insert(type).inserted else { continue }
            if rep.uti == NSPasteboard.PasteboardType.fileURL.rawValue,
               !isFileURLDataValid(rep.data) {
                // 隔空剪贴板/临时文件场景：源已被系统清理，写进剪贴板会变成死链
                continue
            }
            _ = pbItem.setData(rep.data, forType: type)  // 辅助失败容忍：主载体已就位
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
    }

    /// file：每个源 URL 一个独立 NSPasteboardItem（多文件粘到 Finder 才正确分裂）；
    /// 辅助 reps（image bytes / HTML / URL）挂到第一个 pbItem 上——富文本编辑器优先消费它。
    private static func writeFile(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard
    ) -> Bool {
        let paths = FileClipboardContent.paths(from: item.content)
        let urls = paths
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // 全量校验：缺一个都让用户当前剪贴板不动，与 CLAUDE.md 不变量一致
        guard !urls.isEmpty, urls.count == paths.count else { return false }

        let pbItems: [NSPasteboardItem] = urls.map { url in
            let pbItem = NSPasteboardItem()
            pbItem.setString(url.absoluteString, forType: .fileURL)
            return pbItem
        }

        // 辅助 reps 挂到第一个 pbItem。已包含 fileURL 故跳过任何重复 file-url 的 rep。
        if let firstItem = pbItems.first {
            var writtenTypes: Set<NSPasteboard.PasteboardType> = [.fileURL]
            for rep in representations {
                let type = NSPasteboard.PasteboardType(rep.uti)
                guard writtenTypes.insert(type).inserted else { continue }
                _ = firstItem.setData(rep.data, forType: type)  // 辅助失败容忍
            }
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(pbItems)
    }

    /// 校验 reps 副表里的 file-url bytes 指向的文件是否仍存在。
    /// 隔空剪贴板临时文件被系统清理后 reps 里的 file-url 变死链——回放时跳过避免污染剪贴板。
    private static func isFileURLDataValid(_ data: Data) -> Bool {
        guard let urlString = String(data: data, encoding: .utf8) else { return false }
        // file-url bytes 可能末尾带 null 终止符，需 trim
        let trimmed = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let url = URL(string: trimmed), url.isFileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 动作面板 "Paste as X" 入口：仅写一种 UTI。
    /// UTI = public.utf8-plain-text 时从 item.content 重建；其他 UTI 需要 representations 里找得到。
    /// 找不到时返回 false 且 NOT clearContents。
    @discardableResult
    static func writeRepresentation(
        _ item: ClipItem,
        uti: String,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        let data: Data
        if uti == NSPasteboard.PasteboardType.string.rawValue || uti == "public.utf8-plain-text" {
            guard let bytes = item.content.data(using: .utf8) else { return false }
            data = bytes
        } else {
            guard let rep = representations.first(where: { $0.uti == uti }) else {
                return false  // 不 clearContents
            }
            data = rep.data
        }

        // 先把 data 写进游离 pbItem 验证成功，再 clearContents + writeObjects。
        // 不能先 clearContents() 再对 pasteboard 直接 setData：若 setData 失败，
        // 用户当前系统剪贴板已被清空（违反「写剪贴板前必须先验证 payload」）。
        let pbItem = NSPasteboardItem()
        guard pbItem.setData(data, forType: .init(uti)) else { return false }

        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
    }

    /// 以纯文本写回剪贴板（去除富文本格式，图片/文件转为路径文本），成功返回 true
    @discardableResult
    static func writeAsPlainText(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        let text: String

        switch item.clipType {
        case .text, .url:
            text = item.content
        case .image:
            guard let path = item.imagePath else { return false }
            text = path
        case .file:
            text = FileClipboardContent.paths(from: item.content).joined(separator: "\n")
        }

        guard !text.isEmpty else { return false }
        // 与 writeToClipboard/writeAllRepresentations 同一「写前先验证」语义：
        // 先写进游离 pbItem 校验，成功后才清空，避免 setString 失败时擦掉系统剪贴板。
        let pbItem = NSPasteboardItem()
        guard pbItem.setString(text, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
    }

    /// 在 file 类型的 writeToClipboard 返回 false 之后调用，告知调用方失败原因。
    /// 实现上是按现有 writeToClipboard 的 file 校验语义重做一次 stat，
    /// 不与 writeToClipboard 共享代码以避免 Bool 签名被 enum 污染。
    static func fileFailureReason(_ item: ClipItem) -> FilePasteFailureReason {
        guard item.clipType == .file else { return .writeRejected }
        let paths = FileClipboardContent.paths(from: item.content)
        let existingCount = paths.filter { FileManager.default.fileExists(atPath: $0) }.count
        if existingCount == 0 { return .sourceMissing }
        if existingCount < paths.count { return .partial }
        return .writeRejected
    }

    /// 已知终端仿真器的 bundle ID 集合（用于图片粘贴时自动切换到 Ctrl+V）
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "co.zeit.hyper",
    ]

    static func isTerminalApp(_ app: NSRunningApplication?) -> Bool {
        guard let id = app?.bundleIdentifier else { return false }
        return terminalBundleIDs.contains(id)
    }

    /// 模拟粘贴按键。
    /// - `useCtrlV: true` 发送 Ctrl+V（终端 TUI 图片粘贴），默认发送 Cmd+V
    static func simulatePaste(to pid: pid_t? = nil, useCtrlV: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags: CGEventFlags = useCtrlV ? .maskControl : .maskCommand

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.letterV, keyDown: true)
        keyDown?.flags = flags
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.letterV, keyDown: false)
        keyUp?.flags = flags

        if let pid = pid {
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
        } else {
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}
