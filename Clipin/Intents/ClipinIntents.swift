import AppIntents
import AppKit

// App Intents：把 Clipin 接到 Shortcuts / Spotlight / Siri。
// 所有 intent 在 app 进程内执行；需要 UI 的 intent 通过通知交给 AppDelegate，
// 纯数据 intent 直接读 AppState.shared.core（与 UI 同一条数据通路，无副本）。

struct OpenClipinIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Clipin"
    static var description = IntentDescription("Open the Clipin clipboard launcher.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .clipinIntentOpenRequested, object: nil)
        }
        return .result()
    }
}

struct SearchClipinIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Clipin History"
    static var description = IntentDescription("Open Clipin with a search query already filled in.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Query")
    var query: String

    init() {}

    init(query: String) {
        self.query = query
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .clipinIntentSearchRequested, object: query)
        }
        return .result()
    }
}

struct LatestClipboardItemIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Clipboard Item"
    static var description = IntentDescription("Return the most recent clipboard item as plain text. Images return their OCR text, or their file path when no text was recognized.")
    /// 只取数据，不弹面板：Shortcuts 里应静默执行。
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let core = AppState.shared.core
        // 不能复用 getItems：浏览列表可能带类型筛选/展示策略；"最新"由专用查询保证。
        guard let item = try core.getLatestItem() else {
            throw ClipinIntentError.emptyHistory
        }
        return .result(value: Self.plainText(for: item))
    }

    private static func plainText(for item: ClipItem) -> String {
        switch item.clipType {
        case .image:
            if let ocr = item.ocrText, !ocr.isEmpty { return ocr }
            return item.imagePath ?? ""
        default:
            return item.content
        }
    }
}

enum ClipinIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyHistory

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyHistory: return "Clipin history is empty."
        }
    }
}

struct ClipinShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenClipinIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Clipin",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: LatestClipboardItemIntent(),
            phrases: ["Get latest clipboard item from \(.applicationName)"],
            shortTitle: "Latest Item",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}