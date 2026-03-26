import AppKit
import Foundation
import UniformTypeIdentifiers

struct ArchiveExportResult {
    let url: URL
    let exportedCount: Int
    let skippedCount: Int
}

struct ArchiveImportResult {
    let url: URL
    let importedCount: Int
    let skippedCount: Int
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
    static func exportArchive(core: ClipinCore) throws -> ArchiveExportResult {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }

        let items = core.getItems(limit: Int32.max, offset: 0, typeFilter: nil)
        var exportedItems: [ArchiveItem] = []
        var skippedCount = 0

        for item in items {
            if item.clipType == .image {
                guard let imagePath = item.imagePath,
                      let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
                    skippedCount += 1
                    continue
                }

                exportedItems.append(
                    ArchiveItem(
                        content: item.content,
                        clipType: archiveType(for: item.clipType),
                        sourceApp: item.sourceApp,
                        sourceName: item.sourceName,
                        isPinned: item.isPinned,
                        createdAt: item.createdAt,
                        imageDataBase64: imageData.base64EncodedString()
                    )
                )
                continue
            }

            exportedItems.append(
                ArchiveItem(
                    content: item.content,
                    clipType: archiveType(for: item.clipType),
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    imageDataBase64: nil
                )
            )
        }

        let archive = ClipboardArchive(
            schemaVersion: 1,
            exportedAt: Date(),
            items: exportedItems
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
        try data.write(to: url, options: .atomic)

        return ArchiveExportResult(
            url: url,
            exportedCount: exportedItems.count,
            skippedCount: skippedCount
        )
    }

    @MainActor
    static func importArchive(core: ClipinCore) throws -> ArchiveImportResult {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            throw ArchiveError.cancelled
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(ClipboardArchive.self, from: data)

        let imageDirURL = URL(fileURLWithPath: core.imageDir(), isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirURL, withIntermediateDirectories: true)

        var importedCount = 0
        var skippedCount = 0

        for item in archive.items {
            let clipType = runtimeType(for: item.clipType)

            let imagePath: String?
            if clipType == .image {
                guard let imageDataBase64 = item.imageDataBase64,
                      let imageData = Data(base64Encoded: imageDataBase64) else {
                    skippedCount += 1
                    continue
                }

                let destinationURL = imageDirURL.appendingPathComponent(UUID().uuidString + ".png")
                try imageData.write(to: destinationURL, options: .atomic)
                imagePath = destinationURL.path
            } else {
                imagePath = nil
            }

            _ = try core.importItem(
                content: item.content,
                clipType: clipType,
                sourceApp: item.sourceApp,
                sourceName: item.sourceName,
                imagePath: imagePath,
                isPinned: item.isPinned,
                createdAt: item.createdAt
            )
            importedCount += 1
        }

        return ArchiveImportResult(
            url: url,
            importedCount: importedCount,
            skippedCount: skippedCount
        )
    }

    /// 将全部条目写入指定 URL，不弹出文件面板，供自动备份复用。
    static func writeArchive(to url: URL, core: ClipinCore) throws -> ArchiveExportResult {
        let items = core.getItems(limit: Int32.max, offset: 0, typeFilter: nil)
        var exportedItems: [ArchiveItem] = []
        var skippedCount = 0

        for item in items {
            if item.clipType == .image {
                guard let imagePath = item.imagePath,
                      let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) else {
                    skippedCount += 1
                    continue
                }
                exportedItems.append(ArchiveItem(
                    content: item.content,
                    clipType: archiveType(for: item.clipType),
                    sourceApp: item.sourceApp,
                    sourceName: item.sourceName,
                    isPinned: item.isPinned,
                    createdAt: item.createdAt,
                    imageDataBase64: imageData.base64EncodedString()
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
                imageDataBase64: nil
            ))
        }

        let archive = ClipboardArchive(schemaVersion: 1, exportedAt: Date(), items: exportedItems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archive)
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

private struct ClipboardArchive: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let items: [ArchiveItem]
}

private struct ArchiveItem: Codable {
    let content: String
    let clipType: ArchiveClipType
    let sourceApp: String?
    let sourceName: String?
    let isPinned: Bool
    let createdAt: Int64
    let imageDataBase64: String?
}

private enum ArchiveClipType: String, Codable {
    case text
    case image
    case file
    case url
}
