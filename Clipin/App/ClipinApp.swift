import SwiftUI

@main
struct ClipinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app — no main window
        Settings {
            Color.clear
                .frame(width: 1, height: 1)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettingsFromCommand()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
