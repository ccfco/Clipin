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
            CommandGroup(replacing: .appInfo) {
                Button("About Clipin") {
                    appDelegate.openAboutFromCommand()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    appDelegate.checkForUpdatesFromCommand()
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Onboarding") {
                Button("Show Onboarding") {
                    appDelegate.showOnboardingFromCommand()
                }

                Button("Reset Onboarding State") {
                    appDelegate.resetOnboardingStateFromCommand()
                }
            }
        }
    }
}
