import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ArchiveExportResult: Sendable {
    let url: URL
    let exportedCount: Int
    let skippedCount: Int
    /// 输出 archive 文件大小（字节）。设置页 "Last backup · 95 MB" 用。
    let archiveSize: Int64
}

struct ArchiveImportResult: Sendable {
    let url: URL
    let importedCount: Int
    let skippedMissingImageCount: Int
    let skippedDuplicateCount: Int
    /// base64 解码失败而被丢弃的 representation 条数。
    /// 单条 rep 损坏不应让整个 archive 导入失败（item 本体仍可用），
    /// 但「不兜底」要求把损坏暴露出来而不是纯静默，故计数并在结果里上报。
    let failedRepresentationCount: Int

    var skippedCount: Int {
        skippedMissingImageCount + skippedDuplicateCount
    }
}

enum ArchiveError: LocalizedError {
    case cancelled
    case malformedArchive(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .malformedArchive(let detail):
            return String(format: NSLocalizedString("Malformed archive: %@", comment: ""), detail)
        }
    }
}

enum ArchiveService {

    // MARK: - 写出

    @MainActor
    static func exportArchive(core: ClipinCore) async throws -> ArchiveExportResult {
        let panel = NSSavePanel()
        // 仅 .zip：v3 .clipin.zip 在系统 UTType 体系下属于 .zip
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }
        // 手动 export：不留 .previous 旁路。NSSavePanel 的 Replace 语义已经处理
        // 同名冲突，用户期望"覆盖"而非"产生一个 Clipin.previous.zip 副本"——
        // .previous 安全网是自动备份语义，用户主动选位置的快照不应污染用户目录。
        return try await writeArchive(to: url, core: core, preservesPrevious: false)
    }

    /// 写盘，不弹面板；自动备份共用此入口。
    ///
    /// 用 `withThrowingTaskGroup` 把调用方的 cancellation 沿结构化并发链下传：
    /// `writeArchiveSnapshot` 内部多处 `Task.checkCancellation()` 才能真正生效。
    ///
    /// `preservesPrevious`: true（自动备份用）= 旧 destination 改名为 .previous 保留
    /// 作为安全网；false（手动 export 用）= 直接覆盖旧 destination 不留副本。
    /// 默认 true 保持向后兼容——AutoBackupService 等内部调用不带参数即可。
    static func writeArchive(
        to url: URL,
        core: ClipinCore,
        preservesPrevious: Bool = true
    ) async throws -> ArchiveExportResult {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ArchiveExportResult.self) { group in
            group.addTask(priority: .utility) {
                try await Self.writeArchiveSnapshot(
                    to: url,
                    core: core,
                    preservesPrevious: preservesPrevious
                )
            }
            guard let result = try await group.next() else {
                throw ArchiveError.cancelled
            }
            return result
        }
    }

    private static func writeArchiveSnapshot(
        to destinationURL: URL,
        core: ClipinCore,
        preservesPrevious: Bool
    ) async throws -> ArchiveExportResult {
        try Task.checkCancellation()
        // 单快照：item 与其 representations 在同一把 DB 锁内一次性读出。原子性见 Rust 端
        // `Storage::export_archive_snapshot`——任何 SQL 失败/行解码失败直接抛错让整个
        // 导出失败，不把损坏当成「无 representations」掩盖掉。
        let snapshot = try core.exportArchiveSnapshot()

        // staging：在临时目录 attach 元数据 + 图片，最后打包成 zip 再 atomic rename 到目标
        let stagingRoot = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let imagesDir = stagingRoot.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        var archiveItems: [ArchiveItem] = []
        archiveItems.reserveCapacity(snapshot.count)
        var skippedCount = 0
        // 同 image hash 在 zip 内只写一份（用户多次复制同一张图天然 dedup）
        var writtenImageHashes = Set<String>()

        for entry in snapshot {
            try Task.checkCancellation()
            let item = entry.item

            let archiveReps: [ArchiveRepresentation]? = entry.representations.isEmpty
                ? nil
                : entry.representations.map {
                    ArchiveRepresentation(uti: $0.uti, dataBase64: $0.data.base64EncodedString())
                }

            if item.clipType == .image {
                guard let imagePath = item.imagePath else {
                    skippedCount += 1
                    continue
                }
                let imageURL = URL(fileURLWithPath: imagePath)
                guard let imageData = try? Data(contentsOf: imageURL) else {
                    skippedCount += 1
                    continue
                }
                try Task.checkCancellation()

                let hash = sha256Hex(of: imageData)
                if writtenImageHashes.insert(hash).inserted {
                    let dst = imagesDir.appendingPathComponent("\(hash).png")
                    try imageData.write(to: dst, options: .atomic)
                }

                archiveItems.append(ArchiveItem(
                    content: item.content,
                    clipType: archiveType(for: item.clipType),
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    imageDataBase64: nil,   // v3 不再 inline，改 imageHash 指向 zip 内文件
                    imageHash: hash,
                    representations: archiveReps,
                    alias: item.alias
                ))
                continue
            }

            archiveItems.append(ArchiveItem(
                content: item.content,
                clipType: archiveType(for: item.clipType),
                sourceApp: item.sourceApp,
                sourceName: item.sourceName,
                isPinned: item.isPinned,
                createdAt: item.createdAt,
                imageDataBase64: nil,
                imageHash: nil,
                representations: archiveReps,
                alias: item.alias
            ))
        }

        // manifest.json minified：体积主要是 items 数组，prettyPrinted 会让体积翻倍且无可读性收益
        let archive = ClipboardArchive(
            schemaVersion: 3,
            format: "clipin.clipboard-archive",
            // formatURL 历史上指向一个并不存在的 ccfco/Clipin-archive-format 仓库；移除写入
            // 但解码字段保留 Optional，让老 archive 能正常导入
            formatURL: nil,
            exportedAt: Date(),
            summary: ArchiveSummary(itemCount: archiveItems.count, imageCount: writtenImageHashes.count),
            items: archiveItems
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(archive)
        let manifestURL = stagingRoot.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)
        try Task.checkCancellation()

        // 在目标同目录写 .tmp，最后协调 rename
        // 同目录确保 rename 是 atomic（同 volume）。tmp 名带 UUID 避免与并发备份/手动导出冲突
        let parentDir = destinationURL.deletingLastPathComponent()
        let tmpZipURL = parentDir.appendingPathComponent(".\(UUID().uuidString).tmp.clipin.zip")
        // 任何后续步骤失败/取消（zip 写入、Task.checkCancellation、coordinator rename）
        // 都必须把 tmp 文件清掉，否则在备份目录留 .UUID.tmp.clipin.zip 垃圾。
        // 用 defer + 显式 tmpMoved 旗标：成功 rename 后置 true 解除清理。
        var tmpMoved = false
        defer {
            if !tmpMoved {
                try? FileManager.default.removeItem(at: tmpZipURL)
            }
        }
        try await ZipArchiver.zipDirectoryContents(at: stagingRoot, to: tmpZipURL)
        try Task.checkCancellation()

        // 协调写入：preservesPrevious=true（自动备份）→ 旧 destination 升级为 .previous 安全网；
        // preservesPrevious=false（手动 export）→ 直接覆盖旧 destination 不留副本，
        // 不污染用户主动选择的导出位置（NSSavePanel Replace 语义已经处理同名冲突）。
        let previousURL = previousArchiveURL(for: destinationURL)
        try FileCoordination.coordinatedWrite(to: destinationURL) { coordURL in
            if preservesPrevious {
                if FileManager.default.fileExists(atPath: previousURL.path) {
                    try FileManager.default.removeItem(at: previousURL)
                }
                if FileManager.default.fileExists(atPath: coordURL.path) {
                    try FileManager.default.moveItem(at: coordURL, to: previousURL)
                }
            } else {
                if FileManager.default.fileExists(atPath: coordURL.path) {
                    try FileManager.default.removeItem(at: coordURL)
                }
            }
            try FileManager.default.moveItem(at: tmpZipURL, to: coordURL)
            tmpMoved = true
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path))
            .flatMap { $0[.size] as? Int64 } ?? 0
        return ArchiveExportResult(
            url: destinationURL,
            exportedCount: archiveItems.count,
            skippedCount: skippedCount,
            archiveSize: size
        )
    }

    // MARK: - 读入

    @MainActor
    static func importArchive(core: ClipinCore) async throws -> ArchiveImportResult {
        let panel = NSOpenPanel()
        // v3 zip 与 v1/v2 json 都接受；老用户备份不能突然不能导
        panel.allowedContentTypes = [.zip, .json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }
        return try await importArchive(from: url, core: core)
    }

    /// 导入指定 URL，不弹文件面板。重活在后台执行，避免阻塞设置窗口。
    ///
    /// 用 `withThrowingTaskGroup` 而不是 `Task.detached`：后者切断 cancellation 链路，
    /// SettingsView activeOperation 的 cancel 收不到。
    static func importArchive(from url: URL, core: ClipinCore) async throws -> ArchiveImportResult {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ArchiveImportResult.self) { group in
            group.addTask(priority: .utility) {
                try await Self.runImport(from: url, core: core)
            }
            guard let result = try await group.next() else { throw ArchiveError.cancelled }
            return result
        }
    }

    private static func runImport(from url: URL, core: ClipinCore) async throws -> ArchiveImportResult {
        try Task.checkCancellation()
        let imageDirURL = URL(fileURLWithPath: core.imageDir(), isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirURL, withIntermediateDirectories: true)

        // 后缀分流：.zip / .clipin.zip → v3 ；.json → v1/v2
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            return try await runImportFromZip(at: url, core: core, imageDirURL: imageDirURL)
        }
        return try runImportFromJSON(at: url, core: core, imageDirURL: imageDirURL)
    }

    /// v3 zip 导入：解压 → 读 manifest → 按 imageHash 从 staging/images/<hash>.png 取图
    private static func runImportFromZip(
        at zipURL: URL,
        core: ClipinCore,
        imageDirURL: URL
    ) async throws -> ArchiveImportResult {
        let stagingRoot = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        // FileCoordination 的 block 是 sync——无法在里面 await async 的 ZipArchiver。
        // 解法：block 内显式读 1 字节强制触发 iCloud 物化（防 stub），block 退出后
        // 文件已是本地物化态可以放手；block 外 await 真正的 unzip（受 cancellation
        // 保护，import 大文件被 cancel 时不会有遗留 process）。
        // 风险窗口：unzip 期间另一台 Mac 同时改 zip——用户主动 import 场景极罕见，
        // 真发生时表现为 import 失败/不完整，由 ArchiveError 正面暴露不沉默吞掉。
        try FileCoordination.coordinatedRead(at: zipURL) { coordURL in
            let handle = try FileHandle(forReadingFrom: coordURL)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        }
        try await ZipArchiver.unzipArchive(at: zipURL, to: stagingRoot)

        // 拒绝携带 symlink 的归档：恶意 zip 可以放 `images/<hash>.png` symlink 指向
        // 用户敏感文件（/etc/hosts、~/.ssh/id_rsa），import 时读到的就是被链接的内容，
        // 会被复制到 Clipin 库；后续粘贴可能把该内容传出去。`/usr/bin/unzip` 默认
        // 保留 symlink，没有命令行选项跳过，只能后置扫描拒绝。`..` traversal 在现代
        // unzip 上会被静默 sanitize 到 staging 内，不会逃逸出去，不额外校验。
        try rejectSymlinksInStaging(stagingRoot)

        let manifestURL = stagingRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.malformedArchive("manifest.json missing")
        }
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ClipboardArchive.self, from: manifestData)

        let imagesDir = stagingRoot.appendingPathComponent("images", isDirectory: true)
        return try runImportItems(
            archive.items,
            core: core,
            imageDirURL: imageDirURL,
            url: zipURL,
            imageSource: .hashDir(imagesDir)
        )
    }

    /// v1/v2 单 JSON 导入：图片从 item.imageDataBase64 解码（旧格式）
    private static func runImportFromJSON(
        at jsonURL: URL,
        core: ClipinCore,
        imageDirURL: URL
    ) throws -> ArchiveImportResult {
        let data = try Data(contentsOf: jsonURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ClipboardArchive.self, from: data)

        return try runImportItems(
            archive.items,
            core: core,
            imageDirURL: imageDirURL,
            url: jsonURL,
            imageSource: .inlineBase64
        )
    }

    private enum ImageSource {
        case inlineBase64       // v1/v2: 从 item.imageDataBase64 解码
        case hashDir(URL)       // v3: 从 dir/<hash>.png 读
    }

    private static func runImportItems(
        _ items: [ArchiveItem],
        core: ClipinCore,
        imageDirURL: URL,
        url: URL,
        imageSource: ImageSource
    ) throws -> ArchiveImportResult {
        var importedCount = 0
        var skippedMissingImageCount = 0
        var skippedDuplicateCount = 0
        var failedRepresentationCount = 0

        for item in items {
            try Task.checkCancellation()
            let clipType = runtimeType(for: item.clipType)

            let imagePath: String?
            if clipType == .image {
                let imageData: Data?
                switch imageSource {
                case .inlineBase64:
                    imageData = item.imageDataBase64.flatMap { Data(base64Encoded: $0) }
                case .hashDir(let dir):
                    // imageHash 必须是 64 位小写 hex（SHA-256）。这条校验和 symlink 拒绝
                    // 一起防御恶意归档：① 防止 manifest 写 imageHash="../../etc/passwd" 越
                    // 出 staging；② standardizedFileURL 后再核对 path 仍以 dir 为前缀，
                    // 任何路径逃逸都失败成 nil → skippedMissingImageCount。
                    if let hash = item.imageHash, isValidSHA256Hex(hash) {
                        let candidate = dir.appendingPathComponent("\(hash).png").standardizedFileURL
                        let dirStandard = dir.standardizedFileURL.path
                        if candidate.path.hasPrefix(dirStandard) {
                            imageData = try? Data(contentsOf: candidate)
                        } else {
                            imageData = nil
                        }
                    } else {
                        imageData = nil
                    }
                }
                guard let data = imageData else {
                    skippedMissingImageCount += 1
                    continue
                }
                let dst = imageDirURL.appendingPathComponent(UUID().uuidString + ".png")
                try data.write(to: dst, options: .atomic)
                imagePath = dst.path
            } else {
                imagePath = nil
            }

            // base64 解码失败的单条 rep 丢弃但计数：item 本体仍可导入，
            // 不让整个 archive 失败；把损坏暴露给调用方上报，而非纯静默。
            var coreReps: [ClipRepresentation] = []
            for rep in item.representations ?? [] {
                guard let data = Data(base64Encoded: rep.dataBase64) else {
                    failedRepresentationCount += 1
                    continue
                }
                coreReps.append(ClipRepresentation(uti: rep.uti, data: data))
            }

            let didImport: Bool
            do {
                didImport = try core.importItemIfMissing(
                    content: item.content,
                    clipType: clipType,
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    imagePath: imagePath,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    alias: item.alias,
                    representations: coreReps
                )
            } catch {
                if let imagePath {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }
                throw error
            }

            if didImport {
                importedCount += 1
            } else {
                skippedDuplicateCount += 1
                if let imagePath {
                    try? FileManager.default.removeItem(atPath: imagePath)
                }
            }
        }

        return ArchiveImportResult(
            url: url,
            importedCount: importedCount,
            skippedMissingImageCount: skippedMissingImageCount,
            skippedDuplicateCount: skippedDuplicateCount,
            failedRepresentationCount: failedRepresentationCount
        )
    }

    // MARK: - Helpers

    /// `.previous` 兄弟文件路径：在 `.clipin.zip` / `.zip` / `.json` 前插入 `.previous`。
    /// 例如：`clipin-backup.clipin.zip` → `clipin-backup.previous.clipin.zip`。
    static func previousArchiveURL(for archiveURL: URL) -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        let name = archiveURL.lastPathComponent
        let lower = name.lowercased()
        let stem: String
        let suffix: String
        if lower.hasSuffix(".clipin.zip") {
            stem = String(name.dropLast(".clipin.zip".count))
            suffix = ".clipin.zip"
        } else if lower.hasSuffix(".zip") {
            stem = String(name.dropLast(".zip".count))
            suffix = ".zip"
        } else if lower.hasSuffix(".json") {
            stem = String(name.dropLast(".json".count))
            suffix = ".json"
        } else {
            stem = name
            suffix = ""
        }
        return parent.appendingPathComponent("\(stem).previous\(suffix)")
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidSHA256Hex(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        return s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// 扫描 staging 树，发现任何 symlink 立即抛 malformedArchive。
    /// 必须在所有文件读取之前调用，否则恶意 symlink 已经能读到敏感内容。
    private static func rejectSymlinksInStaging(_ stagingRoot: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: stagingRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                throw ArchiveError.malformedArchive("symlink entries not allowed: \(url.lastPathComponent)")
            }
        }
    }

    private static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "Clipin-\(formatter.string(from: .now)).clipin.zip"
    }

    private static func archiveType(for type: ClipType) -> ArchiveClipType {
        switch type {
        case .text: return .text
        case .image: return .image
        case .file: return .file
        case .url: return .url
        }
    }

    private static func runtimeType(for type: ArchiveClipType) -> ClipType {
        switch type {
        case .text: return .text
        case .image: return .image
        case .file: return .file
        case .url: return .url
        }
    }
}

// MARK: - Archive Schema

private struct ClipboardArchive: Codable, Sendable {
    let schemaVersion: Int
    /// v2 起："clipin.clipboard-archive"。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let format: String?
    /// v2 起：规范 URL。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let formatURL: String?
    let exportedAt: Date
    /// v3 起：备份概览（itemCount / imageCount）。v1/v2 没有，Optional。
    let summary: ArchiveSummary?
    let items: [ArchiveItem]
}

private struct ArchiveSummary: Codable, Sendable {
    let itemCount: Int
    let imageCount: Int
}

private struct ArchiveItem: Codable, Sendable {
    let content: String
    let clipType: ArchiveClipType
    let sourceApp: String?
    let sourceName: String?
    let isPinned: Bool
    let createdAt: Int64
    /// v1/v2 only：图片以 base64 inline 嵌入。v3 不再使用，改 imageHash 指向 zip 内文件。
    let imageDataBase64: String?
    /// v3 only：图片字节 SHA256 hex，对应 zip 内 `images/<hash>.png`。
    let imageHash: String?
    /// v2 起：多 UTI representations。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let representations: [ArchiveRepresentation]?
    /// v2.1 起：用户别名。旧 archive 没有该字段，Optional 保证向后兼容解码。
    let alias: String?
}

private struct ArchiveRepresentation: Codable, Sendable {
    let uti: String
    let dataBase64: String
}

private enum ArchiveClipType: String, Codable, Sendable {
    case text
    case image
    case file
    case url
}
