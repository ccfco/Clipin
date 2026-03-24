import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verify Rust-Swift bridge with new ClipinCore API
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let clipinDir = appSupport.appendingPathComponent("Clipin")
        let dbPath = clipinDir.appendingPathComponent("clipin.db").path
        let imageDir = clipinDir.appendingPathComponent("images").path

        // Ensure directories exist
        try? FileManager.default.createDirectory(atPath: clipinDir.path, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: imageDir, withIntermediateDirectories: true)

        do {
            let core = try ClipinCore(dbPath: dbPath, imageDir: imageDir)
            let item = try core.saveItem(
                content: "Hello from Clipin! 🚀",
                clipType: .text,
                sourceApp: "com.ccfco.Clipin",
                sourceName: "Clipin",
                imagePath: nil
            )
            print("🚀 Clipin Core initialized! Saved test item: \(item.content)")

            let items = core.getItems(limit: 10, offset: 0, typeFilter: nil)
            print("📋 Total items in history: \(items.count)")
        } catch {
            print("❌ Failed to initialize ClipinCore: \(error)")
        }

        // Setup menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Clipin")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Clipin v0.1.0", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }
}
