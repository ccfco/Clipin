import Foundation

enum FileClipboardContent {
    static let separator = "\n"

    static func paths(from content: String) -> [String] {
        content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func encodedContent(from paths: [String]) -> String {
        paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }

    static func displayTitle(for content: String) -> String {
        let paths = paths(from: content)
        guard let first = paths.first else { return "File" }

        let firstName = displayName(for: first)
        guard paths.count > 1 else { return firstName }
        return "\(firstName) + \(paths.count - 1) more"
    }

    static func summaryLabel(for content: String) -> String {
        let count = paths(from: content).count
        switch count {
        case 0: return "File"
        case 1: return "1 file"
        default: return "\(count) files"
        }
    }

    static func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }
}
