import AppKit
import Foundation
import UniformTypeIdentifiers

struct ArchiveExportResult: Sendable {
    let url: URL
    let exportedCount: Int
    let skippedCount: Int
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

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        }
    }
}

enum ArchiveService {
    @MainActor
    static func exportArchive(core: ClipinCore) async throws -> ArchiveExportResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }

        return try await writeArchive(to: url, core: core)
    }

    @MainActor
    static func importArchive(core: ClipinCore) async throws -> ArchiveImportResult {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }

        return try await importArchive(from: url, core: core)
    }

    /// 导入指定 URL，不弹出文件面板。重活在后台执行，避免阻塞设置窗口。
    static func importArchive(from url: URL, core: ClipinCore) async throws -> ArchiveImportResult {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(ClipboardArchive.self, from: data)

            let imageDirURL = URL(fileURLWithPath: core.imageDir(), isDirectory: true)
            try FileManager.default.createDirectory(at: imageDirURL, withIntermediateDirectories: true)

            var importedCount = 0
            var skippedMissingImageCount = 0
            var skippedDuplicateCount = 0
            var failedRepresentationCount = 0

            for item in archive.items {
                try Task.checkCancellation()
                let clipType = runtimeType(for: item.clipType)

                let imagePath: String?
                if clipType == .image {
                    guard let imageDataBase64 = item.imageDataBase64,
                          let imageData = Data(base64Encoded: imageDataBase64) else {
                        skippedMissingImageCount += 1
                        continue
                    }

                    let destinationURL = imageDirURL.appendingPathComponent(UUID().uuidString + ".png")
                    try imageData.write(to: destinationURL, options: .atomic)
                    imagePath = destinationURL.path
                } else {
                    imagePath = nil
                }

                // base64 解码失败的单条 rep 丢弃但计数：item 本体仍可导入，
                // 不让整个 archive 失败；同时把损坏暴露给调用方上报，而非纯静默。
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
        }.value
    }

    /// 将全部条目写入指定 URL，不弹出文件面板，供自动备份复用。
    /// 用 `withThrowingTaskGroup` 而不是 `Task.detached`：前者把调用方的 cancellation 沿结构化并发链
    /// 传到子任务，让 `writeArchiveSnapshot` 内部多处 `Task.checkCancellation()` 能真正生效；
    /// 后者会切断 cancellation 链路。
    static func writeArchive(to url: URL, core: ClipinCore) async throws -> ArchiveExportResult {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: ArchiveExportResult.self) { group in
            group.addTask(priority: .utility) {
                try Self.writeArchiveSnapshot(to: url, core: core)
            }

            guard let result = try await group.next() else {
                throw ArchiveError.cancelled
            }
            return result
        }
    }

    private static func writeArchiveSnapshot(to url: URL, core: ClipinCore) throws -> ArchiveExportResult {
        try Task.checkCancellation()
        // 单快照：item 与其 representations 在同一把 DB 锁内一次性读出。
        // 不再「先快照 items 再逐条 getRepresentations」——两次取锁之间条目可能被
        // 删除/CASCADE，导致导出的 v2 archive 静默丢 representations。读取失败直接
        // 抛错让整个导出失败，而不是把损坏当成「无 representations」掩盖掉。
        let snapshot = try core.exportArchiveSnapshot()
        var exportedItems: [ArchiveItem] = []
        exportedItems.reserveCapacity(snapshot.count)
        var skippedCount = 0

        for entry in snapshot {
            try Task.checkCancellation()
            let item = entry.item

            let archiveReps: [ArchiveRepresentation]? = entry.representations.isEmpty
                ? nil
                : entry.representations.map {
                    ArchiveRepresentation(uti: $0.uti, dataBase64: $0.data.base64EncodedString())
                }

            if item.clipType == .image {
                guard let imagePath = item.imagePath,
                      let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
                    skippedCount += 1
                    continue
                }
                try Task.checkCancellation()
                exportedItems.append(ArchiveItem(
                    content: item.content,
                    clipType: archiveType(for: item.clipType),
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    imageDataBase64: imageData.base64EncodedString(),
                    representations: archiveReps
                ))
                continue
            }
            exportedItems.append(ArchiveItem(
                content: item.content,
                clipType: archiveType(for: item.clipType),
                sourceApp: item.sourceApp,
                sourceName: item.sourceName,
                isPinned: item.isPinned,
                createdAt: item.createdAt,
                imageDataBase64: nil,
                representations: archiveReps
            ))
        }

        let archive = ClipboardArchive(
            schemaVersion: 2,
            format: "clipin.clipboard-archive",
            formatURL: "https://github.com/ccfco/Clipin-archive-format",
            exportedAt: Date(),
            items: exportedItems
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)

        return ArchiveExportResult(url: url, exportedCount: exportedItems.count, skippedCount: skippedCount)
    }

    private static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "Clipin-\(formatter.string(from: .now)).json"
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

private struct ClipboardArchive: Codable, Sendable {
    let schemaVersion: Int
    /// v2 起："clipin.clipboard-archive"。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let format: String?
    /// v2 起：规范 URL。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let formatURL: String?
    let exportedAt: Date
    let items: [ArchiveItem]
}

private struct ArchiveItem: Codable, Sendable {
    let content: String
    let clipType: ArchiveClipType
    let sourceApp: String?
    let sourceName: String?
    let isPinned: Bool
    let createdAt: Int64
    let imageDataBase64: String?
    /// v2 起：多 UTI representations。v1 archive 没有该字段，Optional 保证向后兼容解码。
    let representations: [ArchiveRepresentation]?
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
