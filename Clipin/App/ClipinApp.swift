import SwiftUI

@main
struct ClipinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app — no main window
        Settings {
            Text("Clipin Settings")
                .frame(width: 300, height: 200)
        }
    }
}
