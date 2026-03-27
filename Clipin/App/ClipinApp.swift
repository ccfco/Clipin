import SwiftUI

@main
struct ClipinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app — no main window
        Settings {
            SettingsView(
                settings: SettingsStore.shared,
                autoBackup: AutoBackupService.shared,
                navigation: SettingsNavigationModel(),
                core: AppState.shared.core
            )
        }
    }
}
