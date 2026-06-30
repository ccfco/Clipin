import AppKit
import SwiftUI
import Combine

extension AppDelegate {
    // MARK: - Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = statusItemImage(hasPendingUpdate: updateReminder.latestRelease != nil)
            button.action = #selector(statusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    @objc func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            if let latestRelease = updateReminder.latestRelease {
                let updateTitle = String(
                    format: NSLocalizedString("New Version Available: %@", comment: ""),
                    latestRelease.displayVersion
                )
                let updateItem = NSMenuItem(title: updateTitle, action: #selector(openUpdateDetails), keyEquivalent: "")
                updateItem.target = self
                menu.addItem(updateItem)

                let downloadItem = NSMenuItem(title: NSLocalizedString("Install Update", comment: ""), action: #selector(installLatestRelease), keyEquivalent: "")
                downloadItem.target = self
                menu.addItem(downloadItem)

                let releaseItem = NSMenuItem(title: NSLocalizedString("View Release", comment: ""), action: #selector(openReleasePage), keyEquivalent: "")
                releaseItem.target = self
                menu.addItem(releaseItem)

                menu.addItem(NSMenuItem.separator())
            }

            let checkUpdatesItem = NSMenuItem(title: NSLocalizedString("Check for Updates...", comment: ""), action: #selector(checkForUpdates), keyEquivalent: "")
            checkUpdatesItem.target = self
            menu.addItem(checkUpdatesItem)
            let aboutItem = NSMenuItem(title: NSLocalizedString("About Clipin", comment: ""), action: #selector(openAbout), keyEquivalent: "")
            aboutItem.target = self
            menu.addItem(aboutItem)
            menu.addItem(
                NSMenuItem(
                    title: NSLocalizedString("Settings...", comment: ""),
                    action: #selector(openSettings),
                    keyEquivalent: ","
                )
            )
            menu.addItem(NSMenuItem.separator())
            menu.addItem(makeOnboardingMenuItem())
            menu.addItem(NSMenuItem.separator())
            menu.addItem(
                NSMenuItem(
                    title: NSLocalizedString("Quit Clipin", comment: ""),
                    action: #selector(quitApp),
                    keyEquivalent: "q"
                )
            )
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            // 用完后移除 menu，恢复左键 toggle 行为
            statusItem?.menu = nil
        } else {
            togglePanel()
        }
    }

    @objc func openSettings() {
        openSettingsWindow()
    }

    func openAboutFromCommand() {
        openSettingsWindow(select: .about)
    }

    func checkForUpdatesFromCommand() {
        checkForUpdates()
    }

    func showOnboardingFromCommand() {
        showOnboardingForTesting(resetState: false)
    }

    func resetOnboardingStateFromCommand() {
        settings.resetOnboardingForTesting()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func openAbout() {
        openSettingsWindow(select: .about)
    }

    @objc func checkForUpdates() {
        openSettingsWindow(select: .about)
        updateReminder.checkNow()
    }

    @objc func openUpdateDetails() {
        openSettingsWindow(select: .about)
    }

    @objc func openReleasePage() {
        updateReminder.openReleasePage()
    }

    @objc func installLatestRelease() {
        updateReminder.installUpdate()
        updateReminder.dismissActiveReminder()
    }

    func makeOnboardingMenuItem() -> NSMenuItem {
        let onboardingTitle = NSLocalizedString("Onboarding", comment: "")
        let onboardingItem = NSMenuItem(title: onboardingTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: onboardingTitle)

        let showItem = NSMenuItem(
            title: NSLocalizedString("Show Onboarding", comment: ""),
            action: #selector(showOnboardingForDebugMenu),
            keyEquivalent: ""
        )
        showItem.target = self
        submenu.addItem(showItem)

        let resetItem = NSMenuItem(
            title: NSLocalizedString("Reset Onboarding State", comment: ""),
            action: #selector(resetOnboardingStateForDebugMenu),
            keyEquivalent: ""
        )
        resetItem.target = self
        submenu.addItem(resetItem)

        onboardingItem.submenu = submenu
        return onboardingItem
    }

    @objc func showOnboardingForDebugMenu() {
        showOnboardingForTesting(resetState: false)
    }

    @objc func resetOnboardingStateForDebugMenu() {
        settings.resetOnboardingForTesting()
    }

}
