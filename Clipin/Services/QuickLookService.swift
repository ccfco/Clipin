import AppKit

@MainActor
final class QuickLookService {
    private let fileManager = FileManager.default
    private let stagingDirectory: URL
    private var stagedURLs: [URL] = []

    init() {
        stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("clipin-quicklook", isDirectory: true)
    }

    func preparePreviewItems(for item: ClipItem) throws -> [NSURL] {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        clearStagedFiles()

        switch item.clipType {
        case .text:
            let url = stagingDirectory.appendingPathComponent("Clipin Preview.txt")
            try item.content.write(to: url, atomically: true, encoding: .utf8)
            stagedURLs = [url]
            return [url as NSURL]

        case .url:
            guard let destination = URL(string: item.content) else { return [] }
            let url = stagingDirectory.appendingPathComponent("Clipin Link.webloc")
            let payload = ["URL": destination.absoluteString]
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .xml,
                options: 0
            )
            try data.write(to: url, options: .atomic)
            stagedURLs = [url]
            return [url as NSURL]

        case .image:
            guard let path = item.imagePath else { return [] }
            let url = URL(fileURLWithPath: path)
            return fileManager.fileExists(atPath: url.path) ? [url as NSURL] : []

        case .file:
            return FileClipboardContent.paths(from: item.content)
                .map(URL.init(fileURLWithPath:))
                .filter { fileManager.fileExists(atPath: $0.path) }
                .map { $0 as NSURL }
        }
    }

    func clearStagedFiles() {
        for url in stagedURLs {
            try? fileManager.removeItem(at: url)
        }
        stagedURLs.removeAll()
    }
}
