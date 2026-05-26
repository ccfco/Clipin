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
        let pasteboard = NSPasteboard.general

        switch item.clipType {
        case .text, .url:
            // 先把 string(+URL) 写进游离 pbItem 验证成功，再 clearContents + writeObjects。
            // 与 writeAllRepresentations/.image/.file 保持同一「写前先验证 payload」语义，
            // 避免 setString 失败时已清空用户当前系统剪贴板。
            let pbItem = NSPasteboardItem()
            guard pbItem.setString(item.content, forType: .string) else { return false }
            if item.clipType == .url {
                guard pbItem.setString(item.content, forType: .URL) else { return false }
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects([pbItem])

        case .image:
            guard let path = item.imagePath,
                  let image = NSImage(contentsOfFile: path) else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects([image])

        case .file:
            let paths = FileClipboardContent.paths(from: item.content)
            let urls = paths
                .map(URL.init(fileURLWithPath:))
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { $0 as NSURL }
            guard !urls.isEmpty, urls.count == paths.count else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls)
        }
    }

    /// Return 路径的"全量回放"：把所有 representation 写到一个 NSPasteboardItem。
    /// 由调用方（ViewModel/AppDelegate）通过 ClipinCore.getRepresentations 先取出 reps 再传入。
    /// pasteboard 参数仅供测试注入；生产路径走 NSPasteboard.general。
    @discardableResult
    static func writeAllRepresentations(
        _ item: ClipItem,
        representations: [ClipRepresentation],
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard item.clipType == .text || item.clipType == .url else {
            return writeToClipboard(item)
        }

        let pbItem = NSPasteboardItem()

        // 所有写入都先落到游离的 pbItem 并校验返回值；任一失败立即 return false，
        // 此时尚未 clearContents，用户当前系统剪贴板不受影响。全部成功后才 clear+write。
        // setData/setString 对**已存在的同一 type** 会返回 false，故先按 type 去重再写，
        // 避免 url item 的 .URL 与 representations 里的 public.url 冲突导致整体失败（回归）。
        guard pbItem.setString(item.content, forType: .string) else { return false }
        var writtenTypes: Set<NSPasteboard.PasteboardType> = [.string]

        if item.clipType == .url {
            guard pbItem.setString(item.content, forType: .URL) else { return false }
            writtenTypes.insert(.URL)
        }

        for rep in representations {
            let type = NSPasteboard.PasteboardType(rep.uti)
            // 已写过的 type 跳过（数据已在），而不是触发必然失败的重复 setData
            guard writtenTypes.insert(type).inserted else { continue }
            guard pbItem.setData(rep.data, forType: type) else { return false }
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([pbItem])
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
