import Foundation

struct ClipPreviewEntry: Equatable {
    let clipID: String
    let url: URL
}

struct ClipPreviewSession: Equatable {
    let entries: [ClipPreviewEntry]
    let selectedIndex: Int
}

enum ClipPreviewResolver {
    static func resolve(item: ClipItem) -> [ClipPreviewEntry]? {
        let urls: [URL]

        switch item.clipType {
        case .image:
            guard let path = item.imagePath else { return nil }
            urls = existingFileURLs(from: [path])

        case .file:
            urls = existingFileURLs(from: FileClipboardContent.paths(from: item.content))

        case .url:
            guard let url = URL(string: item.content) else { return nil }
            urls = [url]

        default:
            return nil
        }

        guard !urls.isEmpty else { return nil }
        return urls.map { ClipPreviewEntry(clipID: item.id, url: $0) }
    }

    static func resolveSession(
        items: [ClipListItem],
        selectedItemID: String?,
        neighborItemLimit: Int? = nil,
        loadItem: (String) -> ClipItem?
    ) -> ClipPreviewSession? {
        guard let selectedItemID else { return nil }
        guard let selectedItemIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            return nil
        }

        let candidateItems: ArraySlice<ClipListItem>
        if let neighborItemLimit {
            let lowerBound = max(items.startIndex, selectedItemIndex - max(0, neighborItemLimit))
            let upperBound = min(items.index(before: items.endIndex), selectedItemIndex + max(0, neighborItemLimit))
            candidateItems = items[lowerBound...upperBound]
        } else {
            candidateItems = items[items.startIndex..<items.endIndex]
        }

        var entries: [ClipPreviewEntry] = []
        var selectedIndex: Int?

        for item in candidateItems {
            let itemEntries = resolve(listItem: item, loadItem: loadItem)
            if selectedIndex == nil, item.id == selectedItemID, !itemEntries.isEmpty {
                selectedIndex = entries.count
            }
            entries.append(contentsOf: itemEntries)
        }

        guard !entries.isEmpty, let selectedIndex else { return nil }
        return ClipPreviewSession(entries: entries, selectedIndex: selectedIndex)
    }

    private static func existingFileURLs(from paths: [String]) -> [URL] {
        paths.compactMap { path in
            guard !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    private static func resolve(listItem: ClipListItem, loadItem: (String) -> ClipItem?) -> [ClipPreviewEntry] {
        switch listItem.clipType {
        case .image:
            guard let path = listItem.imagePath else { return [] }
            return existingFileURLs(from: [path]).map { ClipPreviewEntry(clipID: listItem.id, url: $0) }

        case .file, .url:
            guard let item = loadItem(listItem.id) else { return [] }
            return resolve(item: item) ?? []

        default:
            return []
        }
    }
}
