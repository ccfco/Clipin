import AppKit
import SwiftUI
import Combine

extension AppDelegate {
    // MARK: - Paste

    func performPaste(_ item: ClipItem) {
        monitor?.pause()

        let representations: [ClipRepresentation]
        if item.clipType == .text || item.clipType == .url {
            do {
                representations = try appState.core.getRepresentations(id: item.id)
            } catch {
                // DB 读 representations 失败不能 ?? [] 静默退化成“只写纯文本”——
                // 用户期待 HTML/RTF 跟着粘贴，悄悄丢格式属于“不兜底”里禁止的兜底行为。
                ClipinLog.paste.error("Failed to load representations for paste: \(error.localizedDescription, privacy: .public)")
                monitor?.resume()
                viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
                return
            }
        } else {
            representations = []
        }

        guard PasteService.writeAllRepresentations(item, representations: representations) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { ClipinLog.paste.error("Failed to increment paste count id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }

        // 富文本首次粘贴的教育提示：告诉用户额外格式被保留。
        // 仅在连续粘贴模式触发——普通模式 executePasteFlow 会立即 hidePanel，
        // launcher notice 根本来不及被看到（与 performCopy 的 notice 同一约束）。
        // representations 只含 plain text 之外的额外 UTI，总格式数需 +1。
        if viewModel?.isContinuousPasteEnabled == true,
           !representations.isEmpty,
           settings.richPasteNoticeCountSeen < 3 {
            viewModel?.showNotice(
                String(
                    format: NSLocalizedString("notice.pastedWithFormats", comment: ""),
                    representations.count + 1
                ),
                style: .success
            )
            settings.richPasteNoticeCountSeen += 1
        }

        executePasteFlow(isImage: item.clipType == .image)
    }

    func performPastePlain(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeAsPlainText(item) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { ClipinLog.paste.error("Failed to increment paste count id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        executePasteFlow(isImage: false)
    }

    func performPasteRepresentation(_ item: ClipItem, uti: String) {
        monitor?.pause()
        let representations: [ClipRepresentation]
        do {
            representations = try appState.core.getRepresentations(id: item.id)
        } catch {
            // 同 performPaste：⌥H / ⌥R 走的是“按 UTI 取格式回写”，
            // representations 读不到 ?? [] 会让 writeRepresentation 直接失败，
            // 但报错语义会变得模糊（看起来像“格式不支持”而非 DB 失败），所以显式上报。
            ClipinLog.paste.error("Failed to load representations for paste(\(uti, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        guard PasteService.writeRepresentation(item, uti: uti, representations: representations) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        do { try appState.core.incrementPasteCount(id: item.id) } catch { ClipinLog.paste.error("Failed to increment paste count id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        executePasteFlow(isImage: false)
    }

    /// 连续粘贴模式下实时查询 frontmostApplication 作为粘贴目标（LSUIElement app 不会成为 frontmostApplication）；
    /// 非连续粘贴模式使用 showPanel 时快照的 previousApp。
    func resolveTargetApp() -> NSRunningApplication? {
        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        if continuousPasteEnabled {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
        }
        return previousApp
    }

    func executePasteFlow(isImage: Bool = false) {
        let permission = PermissionManager.shared
        permission.checkNow()

        guard permission.isAccessibilityGranted else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Accessibility permission is required to paste automatically.", comment: ""), style: .warning)
            showPermissionWindowIfNeeded(permission, activateApp: true)
            return
        }

        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        let targetApp = resolveTargetApp()

        // 粘贴流程中抑制 resignKey 自动夺回，避免和下面的手动夺回竞争
        if continuousPasteEnabled { suppressResignKey = true }

        if !continuousPasteEnabled {
            hidePanel()
        }

        // 激活目标并精准投递粘贴事件
        targetApp?.activate()

        let useCtrlV = isImage
            && SettingsStore.shared.useCtrlVInTerminalForImages
            && PasteService.isTerminalApp(targetApp)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            PasteService.simulatePaste(to: targetApp?.processIdentifier, useCtrlV: useCtrlV)
            self?.monitor?.resume()

            if continuousPasteEnabled {
                self?.suppressResignKey = false
                self?.scheduleContinuousPasteFocusRestore(after: 0.15)
            }
        }
    }

    func performCopy(_ item: ClipItem) {
        monitor?.pause()
        guard PasteService.writeToClipboard(item) else {
            monitor?.resume()
            viewModel?.showNotice(NSLocalizedString("Could not write this item to the clipboard.", comment: ""), style: .error)
            return
        }
        let continuousPasteEnabled = viewModel?.isContinuousPasteEnabled ?? false
        if continuousPasteEnabled {
            viewModel?.showNotice(NSLocalizedString("Copied to clipboard.", comment: ""), style: .success)
        }
        if !continuousPasteEnabled { hidePanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.monitor?.resume()
            if continuousPasteEnabled {
                NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
            }
        }
    }
}
