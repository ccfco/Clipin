import Combine
import Foundation
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var retentionDays: Int {
        didSet {
            let clamped = max(1, min(retentionDays, 365))
            guard retentionDays == clamped else {
                retentionDays = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.retentionDays)
        }
    }

    @Published var maxHistoryItems: Int {
        didSet {
            let clamped = max(50, min(maxHistoryItems, 5_000))
            guard maxHistoryItems == clamped else {
                maxHistoryItems = clamped
                return
            }
            defaults.set(clamped, forKey: Keys.maxHistoryItems)
        }
    }

    @Published var shortcut: HotKeyShortcut {
        didSet {
            guard let data = try? encoder.encode(shortcut) else { return }
            defaults.set(data, forKey: Keys.shortcut)
        }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNote: String?

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let retentionDays = "settings.retentionDays"
        static let maxHistoryItems = "settings.maxHistoryItems"
        static let shortcut = "settings.shortcut"
    }

    private init() {
        let decoder = JSONDecoder()
        let storedRetention = defaults.object(forKey: Keys.retentionDays) as? Int ?? 30
        let storedMaxItems = defaults.object(forKey: Keys.maxHistoryItems) as? Int ?? 500
        let storedShortcut = defaults.data(forKey: Keys.shortcut)
            .flatMap { try? decoder.decode(HotKeyShortcut.self, from: $0) }
            ?? .default

        self.retentionDays = storedRetention
        self.maxHistoryItems = storedMaxItems
        self.shortcut = storedShortcut
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginNote = "Clipin will start automatically after you log in."
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginNote = "Login launch is pending approval in System Settings."
        default:
            launchAtLoginEnabled = false
            launchAtLoginNote = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginNote = error.localizedDescription
        }
    }
}
