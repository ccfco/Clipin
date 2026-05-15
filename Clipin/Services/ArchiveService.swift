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
                        representations: []   // Task 5.3 接通时改为真实数据
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
                skippedDuplicateCount: skippedDuplicateCount
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
        let items = core.exportItemsSnapshot()
        var exportedItems: [ArchiveItem] = []
        exportedItems.reserveCapacity(items.count)
        var skippedCount = 0

        for item in items {
            try Task.checkCancellation()

            // 取 representations 用 try?：导出过程中 representations 取失败不应该让整个 archive 失败；
            // 当成无 representations 处理即可。
            let coreReps = (try? core.getRepresentations(id: item.id)) ?? []
            let archiveReps: [ArchiveRepresentation]? = coreReps.isEmpty ? nil : coreReps.map {
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
