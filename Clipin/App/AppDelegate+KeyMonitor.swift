import AppKit
import SwiftUI
import Combine

extension AppDelegate {
    // MARK: - Key Monitor

    func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // 修饰键变化:驱动「长按 ⌘」浮出快速粘贴数字提示。必须 return event
            // 不消费,否则会破坏系统对修饰键的正常处理。
            if event.type == .flagsChanged {
                // 仅当焦点在主面板(含其动作面板 overlay)时才驱动数字提示:
                // 设置 / 引导窗口是独立 window,在那里长按 ⌘ 不应触发,否则会
                // 写脏 isShortcutHintVisible 且无对应复位路径。⌘K 后上下文变为
                // .actionsPalette,松开 ⌘ 的事件仍需被处理来收起提示——它和
                // .mainPanel 同属主面板那一个 window,故一并放行。
                switch self.keyboardContext {
                case .mainPanel, .actionsPalette:
                    // 仅「纯 ⌘」长按才浮出:叠加 Shift/Option/Control 说明在组装
                    // ⌘⇧P 这类组合键(或刚用 ⌘⇧V 热键唤起面板还没松手),不是长按。
                    let isPureCommand = flags.contains(.command)
                        && flags.isDisjoint(with: [.shift, .option, .control])
                    self.updateCommandHoldState(isHeld: isPureCommand)
                default:
                    break
                }
                return event
            }

            // 真实按键到达 = 用户在按组合键(⌘K / ⌘1…),不是纯长按 ⌘ →
            // 取消尚未触发的延迟显示。已浮出的提示不在此隐藏(松开 ⌘ 才收)。
            self.cancelPendingShortcutHintReveal()

            switch self.keyboardContext {
            case .onboarding(let flow):
                return self.handleOnboardingKeyEvent(event, flags: flags, flow: flow)
            case .actionsPalette(let vm):
                return self.handlePaletteKeyEvent(event, flags: flags, viewModel: vm)
            case .renamingItem(let vm):
                return self.handleRenamingKeyEvent(event, viewModel: vm)
            case .editingContent(let vm):
                return self.handleEditingContentKeyEvent(event, flags: flags, viewModel: vm)
            case .mainPanel(let vm):
                return self.handlePanelKeyEvent(event, flags: flags, viewModel: vm)
            case .settingsWindow(let nav):
                return self.handleSettingsKeyEvent(event, navigation: nav)
            case .none:
                return event
            }
        }
    }

    // MARK: - 「长按 ⌘」数字提示

    /// 处理「纯 ⌘ 按住」状态的进入 / 退出。进入后延迟 `commandHoldRevealDelay`
    /// 再浮出数字提示,形成真正的「长按」手势(区别于 ⌘K / ⌘1 这类瞬时组合键);
    /// 退出(松开 ⌘ 或叠加其它修饰键)立即收起。
    func updateCommandHoldState(isHeld: Bool) {
        // 仅在「纯 ⌘ 按住」状态真正翻转时处理,重复回调直接忽略。
        guard isHeld != isPureCommandHeld else { return }
        isPureCommandHeld = isHeld

        guard isHeld else {
            // 退出纯 ⌘ 状态(松开 ⌘ 或叠加其它修饰键):取消待定计时并立即收起提示。
            cancelPendingShortcutHintReveal()
            setShortcutHintVisible(false)
            return
        }

        // 进入纯 ⌘ 状态:排一个延迟任务,期满时若仍是纯 ⌘ 按住且未被按键打断才浮出。
        commandHoldTask?.cancel()
        commandHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.commandHoldRevealDelay)
            guard !Task.isCancelled, let self, self.isPureCommandHeld else { return }
            self.commandHoldTask = nil
            self.setShortcutHintVisible(true)
        }
    }

    /// 取消尚未触发的「长按 ⌘」延迟显示任务(已浮出的提示不受影响)。
    func cancelPendingShortcutHintReveal() {
        commandHoldTask?.cancel()
        commandHoldTask = nil
    }

    /// 幂等写入数字提示可见性——避免无谓的列表重渲染。
    func setShortcutHintVisible(_ visible: Bool) {
        guard let vm = viewModel, vm.isShortcutHintVisible != visible else { return }
        vm.isShortcutHintVisible = visible
    }

    /// 彻底复位「长按 ⌘」状态。面板关闭或失焦后本 app 收不到 .flagsChanged,
    /// 必须在这些路径上 fail-closed 复位,否则会残留过期的数字提示。
    func resetShortcutHint() {
        cancelPendingShortcutHintReveal()
        isPureCommandHeld = false
        setShortcutHintVisible(false)
    }

    /// 为历史图片补跑 OCR（仅处理 ocr_text 为 NULL 的条目，分页直到处理完毕）
    /// 使用 .background 优先级串行处理，不影响 UI 和正常的新图片 OCR；
    /// Task 存储在 backfillTask 供 applicationWillTerminate 取消
    func backfillOcrForExistingImages() {
        let core = appState.core
        backfillTask = Task.detached(priority: .background) {
            let pageSize: Int32 = 20
            var totalProcessed = 0

            // 每次取最早的 N 条未处理图片（ocr_text IS NULL），处理后再取下一批
            // 无 offset，新增图片不会导致分页跳过
            while !Task.isCancelled {
                // getUnprocessedImages 现在 throws：旧实现的 unwrap_or_default 会让 SQL
                // 错误"伪装成已处理完"——backfill 直接 break；按 "不兜底" 必须 log 错误
                // 并退出循环（短时间内重试也很难成功，下次启动会重跑）。
                let pending: [ClipItem]
                do {
                    pending = try core.getUnprocessedImages(limit: pageSize)
                } catch {
                    ClipinLog.ocr.error("OCR backfill query failed, aborting this session: \(error.localizedDescription, privacy: .public)")
                    break
                }
                if pending.isEmpty { break }

                for item in pending {
                    guard !Task.isCancelled else { break }

                    guard let path = item.imagePath else {
                        // updateOcrText 失败仅意味着这次没标记完成，下次启动会再扫到——
                        // 这里 log 后继续即可，不阻断 backfill。
                        do { try core.updateOcrText(id: item.id, ocrText: "") }
                        catch { ClipinLog.ocr.error("OCR backfill mark-empty failed id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                        continue
                    }
                    guard FileManager.default.fileExists(atPath: path) else {
                        do { try core.updateOcrText(id: item.id, ocrText: "") }
                        catch { ClipinLog.ocr.error("OCR backfill mark-empty failed id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                        continue
                    }

                    let text = await OcrService.recognizeText(at: path)
                    do {
                        try core.updateOcrText(id: item.id, ocrText: text)
                        if !text.isEmpty {
                            NotificationCenter.default.post(name: .clipboardItemOcrUpdated, object: nil)
                        }
                        totalProcessed += 1
                    } catch {
                        ClipinLog.ocr.error("OCR backfill write error id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            if totalProcessed > 0 {
                ClipinLog.ocr.notice("OCR backfill complete: \(totalProcessed, privacy: .public) image(s) processed")
            }
        }
    }

    /// 启动时清理 imageDir 中的孤儿 PNG：file 类型采集中 PNG 已落盘但 DB save 没完成
    /// 就崩溃/Kill 时累积的废文件。R1 修复（Codex review b1d5181）。
    /// detach 后台跑——文件扫描和 DB 查询都不阻塞主线程；启动时一次即可。
    /// max_age_seconds=300 保护 5 分钟内的文件不被误删（保留 in-flight 采集冗余窗口）。
    func reconcileOrphanAttachments() {
        let core = appState.core
        Task.detached(priority: .background) {
            do {
                let removed = try core.reconcileOrphanAttachments(maxAgeSeconds: 300)
                if removed > 0 {
                    ClipinLog.monitor.info("Reconciled \(removed, privacy: .public) orphan attachment PNG(s) at startup")
                }
            } catch {
                ClipinLog.monitor.error("Orphan attachment reconcile failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 为历史图片补测像素尺寸（仅处理 image_width 为 NULL 的条目，分页直到处理完毕）。
    /// 与 OCR backfill 同构，但每条都必须写回一个值：成功写真实尺寸，文件缺失 / 不可解析
    /// 写 0×0 哨兵——否则 getUnsizedImages 会反复返回同一批，while 循环无法收敛。
    /// 读尺寸只解析图片头，开销极小，用 .background 串行处理不影响 UI。
    func backfillImageDimensionsForExistingImages() {
        let core = appState.core
        dimensionBackfillTask = Task.detached(priority: .background) {
            let pageSize: Int32 = 50
            var totalProcessed = 0

            backfillLoop: while !Task.isCancelled {
                let pending: [ClipItem]
                do {
                    pending = try core.getUnsizedImages(limit: pageSize)
                } catch {
                    ClipinLog.imageDimensions.error("尺寸 backfill 查询失败，本次中止: \(error.localizedDescription, privacy: .public)")
                    break
                }
                if pending.isEmpty { break }

                for item in pending {
                    guard !Task.isCancelled else { break }
                    // 文件缺失 / 不可解析时落 0×0 哨兵，让条目离开 image_width IS NULL
                    // 集合，避免下次分页再次扫到造成死循环。displayTitle 对 0 尺寸不渲染。
                    let size = item.imagePath.flatMap { ImageDimensions.read(at: $0) }
                    let (width, height) = size ?? (0, 0)
                    do {
                        try core.updateImageDimensions(
                            id: item.id, width: width, height: height)
                        totalProcessed += 1
                    } catch {
                        // 写入失败若只 print+continue，该条仍是 image_width IS NULL，
                        // 下一页会再次扫到 → tight loop。按 "不兜底"：中止本次 backfill，
                        // log 后让下次启动重试（DB 写失败是系统性问题，硬扛无意义）。
                        ClipinLog.imageDimensions.error("尺寸 backfill 写入失败，本次中止 id=\(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        break backfillLoop
                    }
                }
            }

            if totalProcessed > 0 {
                ClipinLog.imageDimensions.notice("图片尺寸 backfill 完成: \(totalProcessed, privacy: .public) 张")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.finalizePendingDeletion()
        backfillTask?.cancel()
        dimensionBackfillTask?.cancel()
        tearDownEventObservers()
    }

    /// 统一清理本类持有的所有 event observer / monitor / service。
    /// 旧的 willTerminate 只关 backfill + activeSpace observer——进程退出虽然会被
    /// 系统强制回收，但语义不完整：hide/quit 路径不一致，未来若改成 LSUIElement
    /// "切到后台保留进程" 的形态，遗漏的 observer 会变成真实泄漏。这里收口成单一入口。
    func tearDownEventObservers() {
        stopActiveSpaceObserver()
        stopAppSwitchObserver()
        stopClickOutsideMonitor()
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        monitor?.stop()
        hotKey.stop()
    }

    func runCleanupAndReload(selectLatest: Bool = false) {
        let cleanup = cleanupService
        viewModel?.loadItems(selectLatest: selectLatest)
        Task { @MainActor [weak self] in
            // 自动清理失败需要 log（旧实现 try? 直接吞错），历史膨胀/文件删除失败
            // 长期隐藏的根因都丢了。这里不向用户 toast（自动清理是后台行为），
            // 用户主动清理由 SettingsView 入口自带 notice 路径。
            do {
                let result = try await cleanup.runNow()
                if result.totalRemoved > 0 {
                    self?.viewModel?.loadItems()
                }
            } catch {
                ClipinLog.cleanup.error("runCleanupAndReload failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func handleEscape(for vm: ClipboardViewModel) {
        if vm.clearActiveQueryAndFilters() {
            return
        }
        hidePanel()
    }

    var keyboardContext: KeyboardContext {
        if let onboardingWindow, onboardingWindow.isVisible, onboardingWindow.isKeyWindow, let onboardingFlow {
            return .onboarding(onboardingFlow)
        }
        if let panel, panel.isVisible, panel.isKeyWindow, let viewModel {
            if viewModel.renamingItemID != nil { return .renamingItem(viewModel) }
            if viewModel.editingContentItemID != nil { return .editingContent(viewModel) }
            return viewModel.isShowingActions ? .actionsPalette(viewModel) : .mainPanel(viewModel)
        }
        if let settingsWindow, settingsWindow.isVisible, settingsWindow.isKeyWindow {
            return .settingsWindow(settingsNavigation)
        }
        return .none
    }

    func handleOnboardingKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, flow: OnboardingFlow) -> NSEvent? {
        // 注意：方向键的 modifierFlags 里始终包含 .function/.numericPad，不能用全局 flags.isEmpty guard
        switch event.keyCode {
        case KeyCode.arrowLeft, KeyCode.arrowUp:
            flow.goBack()
            return nil
        case KeyCode.arrowRight, KeyCode.arrowDown:
            if flow.step == .welcome || flow.step == .workflow {
                flow.move(1)
                return nil
            }
            return event
        case KeyCode.returnKey where flags.isEmpty:
            flow.activatePrimary()
            return nil
        case KeyCode.escape:
            flow.goBack()
            return nil
        default:
            return event
        }
    }

    func handleSettingsKeyEvent(_ event: NSEvent, navigation: SettingsNavigationModel) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.arrowUp:   navigation.selectPrev(); return nil
        case KeyCode.arrowDown: navigation.selectNext(); return nil
        default:                return event
        }
    }

    func handlePaletteKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        // 与 handlePanelKeyEvent 对齐：IME 组词期间（搜索框正在拼音输入时按 ⌘K 打开
        // palette），方向/回车/字符/空格/Esc 全部归还给系统让 IME 继续选字。
        // 旧实现 palette 分支没做此检查，导致 IME 字符被 palette 截走、选字面板异常。
        if isIMEComposingInPanel() {
            switch event.keyCode {
            case KeyCode.tab, KeyCode.arrowUp, KeyCode.arrowDown,
                 KeyCode.returnKey, KeyCode.space, KeyCode.escape:
                return event
            default:
                break
            }
        }

        if let shortcut = PaletteActionShortcut.matching(keyCode: event.keyCode, flags: flags),
           vm.executePaletteShortcut(shortcut) {
            return nil
        }

        // 「粘贴为…」子面板打开时,↑↓/Return/Esc 路由到子面板;
        // Esc 只回退到主命令面板(不关整个面板),⌘K 仍整体关闭。
        if vm.isShowingSubPalette {
            switch event.keyCode {
            case KeyCode.arrowUp:
                vm.navigateSubPalette(delta: -1)
                return nil
            case KeyCode.arrowDown:
                vm.navigateSubPalette(delta: 1)
                return nil
            case KeyCode.returnKey where flags.isEmpty:
                vm.executeSelectedSubPaletteAction()
                return nil
            case KeyCode.letterK where flags == .command:
                vm.hideActionsPalette(restoreFocus: true)
                return nil
            case KeyCode.escape:
                vm.closeSubPalette()
                return nil
            case KeyCode.tab, KeyCode.delete:
                return nil
            default:
                return nil
            }
        }

        switch event.keyCode {
        case KeyCode.arrowUp:
            vm.navigatePalette(delta: -1)
            return nil
        case KeyCode.arrowDown:
            vm.navigatePalette(delta: 1)
            return nil
        case KeyCode.returnKey where flags.isEmpty:
            vm.executeSelectedPaletteAction()
            return nil
        case KeyCode.letterK where flags == .command:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case KeyCode.escape:
            vm.hideActionsPalette(restoreFocus: true)
            return nil
        case KeyCode.tab, KeyCode.delete:
            return nil
        default:
            return nil
        }
    }

    func handleRenamingKeyEvent(_ event: NSEvent, viewModel vm: ClipboardViewModel) -> NSEvent? {
        if event.keyCode == KeyCode.escape {
            vm.cancelRenaming()
            return nil
        }
        // 其余按键（含 Return / ↑↓ / Tab / Space / ⌘1-9 / IME 组词）全部交还给 inline TextField。
        return event
    }

    func handleEditingContentKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.returnKey where flags == .command:
            vm.commitEditContent()
            return nil
        case KeyCode.escape:
            vm.cancelEditContent()
            return nil
        default:
            // 其余按键（含普通 Return 换行、IME 组词、方向键）交还给 TextEditor。
            return event
        }
    }

    func isIMEComposingInPanel() -> Bool {
        if let textView = panel?.firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        return false
    }

    /// 焦点是否在文本编辑控件(搜索框 field editor / Edit Content TextEditor / 文本预览的
    /// SelectableTextPreview NSTextView)。是 → ← →/⌫/普通字符等应按"光标移动 / 编辑文本"
    /// 处理,不应被全局快捷键抢走。
    func isTextEditingInPanel() -> Bool {
        if panel?.firstResponder is NSTextView { return true }
        if NSApp.keyWindow?.firstResponder is NSTextView { return true }
        return false
    }

    /// ← → 是否应让给文本编辑控件而非走全局路由(叠放卡切换)。
    /// 关键区分:
    /// - 搜索框 field editor + 有文本 → 让给搜索框移光标(用户在打字修错)
    /// - 搜索框 field editor + 空文本 → 全局路由(panel 默认聚焦,用户没在打字,应允许切栈)
    /// - 自定义 NSTextView(文本预览选区) → 让给编辑器(选区/光标真的在移动)
    /// `isFieldEditor` 区分"系统共享 field editor"(NSTextField 单行输入)和"自定义 NSTextView"(预览/TextEditor)。
    func shouldArrowKeyDeferToTextEditing() -> Bool {
        guard let vm = viewModel else { return false }
        if let textView = panel?.firstResponder as? NSTextView {
            if textView.isFieldEditor {
                // 搜索框 / 任何单行 NSTextField 的 field editor
                return !vm.searchQuery.isEmpty
            }
            // 自定义 NSTextView(预览选区等)
            return true
        }
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            if textView.isFieldEditor {
                return !vm.searchQuery.isEmpty
            }
            return true
        }
        return false
    }

    func handlePanelKeyEvent(_ event: NSEvent, flags: NSEvent.ModifierFlags, viewModel vm: ClipboardViewModel) -> NSEvent? {
        if isIMEComposingInPanel() {
            switch event.keyCode {
            case KeyCode.tab, KeyCode.arrowUp, KeyCode.arrowDown,
                 KeyCode.returnKey, KeyCode.space, KeyCode.escape:
                return event
            default:
                break
            }
        }

        switch event.keyCode {
        case KeyCode.tab where flags.isEmpty:
            vm.cycleBrowseMode()
            return nil
        case KeyCode.tab where flags == .shift:
            vm.cycleBrowseMode(reverse: true)
            return nil
        case KeyCode.arrowUp:
            vm.selectPrev()
            return nil
        case KeyCode.arrowDown:
            vm.selectNext()
            return nil
        case KeyCode.arrowLeft:
            // 双向兼容:搜索框有文本时 ← 留给光标移动(避免用户打字时被吞);
            // 搜索框空(panel 默认聚焦无文本)或焦点不在搜索框时,← 走全局路由切换多文件叠放栈。
            // 自定义 NSTextView(预览选区)永远留给编辑器。
            if shouldArrowKeyDeferToTextEditing() { return event }
            return vm.stepFileAttachmentPreview(delta: -1) ? nil : event
        case KeyCode.arrowRight:
            if shouldArrowKeyDeferToTextEditing() { return event }
            return vm.stepFileAttachmentPreview(delta: 1) ? nil : event
        case KeyCode.returnKey where flags.isEmpty:
            vm.pasteSelected()
            return nil
        case KeyCode.space where flags.isEmpty:
            // 其余情况 Space 是 launcher 保留键，有可预览项则预览，否则吞掉
            if vm.canPreviewSelectedItem {
                _ = vm.previewSelected()
            }
            return nil
        case KeyCode.returnKey where flags == .shift:
            vm.pastePlainSelected()
            return nil
        case KeyCode.escape:
            handleEscape(for: vm)
            return nil
        case KeyCode.letterP where flags == [.command, .shift]:
            vm.togglePinSelected()
            return nil
        case KeyCode.delete where flags == .command:
            // 文本预览区编辑时（NSTextView 为 firstResponder），⌘⌫ 是系统"删到行首"，
            // 不能被全局路由吃掉变成"删除当前剪贴板条目"——会误删用户正在阅读的项。
            // 判断收到 LauncherKeyRouting helper 以便单测覆盖（ActionPaletteShortcutTests）。
            if LauncherKeyRouting.shouldPreserveTextEditing(
                keyCode: event.keyCode,
                flags: flags,
                firstResponderIsTextView: self.panel?.firstResponder is NSTextView
            ) {
                return event
            }
            vm.deleteSelected()
            return nil
        case KeyCode.letterO where flags == .command:
            vm.openSelected()
            return nil
        case KeyCode.letterC where flags == .command:
            if let responder = self.panel?.firstResponder as? NSTextView,
               responder.selectedRange().length > 0 {
                return event
            }
            vm.copySelected()
            return nil
        case KeyCode.letterE where flags == [.command, .shift]:
            // ⇧⌘E / ⌘E 在主面板直达：选中项可见时无需先开 ⌘K。
            // 必须 return nil 消费事件——否则事件回落到响应链无人处理，系统会「咚」一声。
            vm.beginRenamingSelected()
            return nil
        case KeyCode.letterE where flags == .command:
            vm.beginEditContentSelected()
            return nil
        case KeyCode.letterK where flags == .command:
            vm.toggleActionsPalette()
            return nil
        case KeyCode.comma where flags == .command:
            if !vm.isContinuousPasteEnabled { self.hidePanel() }
            self.openSettingsWindow()
            return nil
        case KeyCode.letterL where flags == [.command, .shift]:
            vm.toggleContinuousPaste()
            return nil
        case KeyCode.letterH where flags == .option:
            if vm.selectedRepresentationUTIs.contains("public.html") {
                vm.pasteRepresentationSelected(uti: "public.html")
            }
            return nil
        case KeyCode.letterR where flags == .option:
            if vm.selectedRepresentationUTIs.contains("public.rtf") {
                vm.pasteRepresentationSelected(uti: "public.rtf")
            }
            return nil
        default:
            if flags == .command,
               let char = event.charactersIgnoringModifiers,
               let digit = char.first?.wholeNumberValue,
               (1...9).contains(digit) {
                vm.pasteItemAt(index: digit - 1)
                return nil
            }
            if flags == .option, let mode = Self.optionDigitBrowseMode[event.keyCode] {
                vm.browseMode = mode
                return nil
            }
            return event
        }
    }

    func handlePreviewVisibilityChange(isVisible: Bool) {
        guard !isVisible,
              viewModel?.isContinuousPasteEnabled == true,
              settingsWindow?.isVisible != true,
              permissionWindow?.isVisible != true,
              let panel,
              panel.isVisible else { return }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .clipinRestoreSearchFocus, object: nil)
    }

    /// 三个辅助窗口（设置 / 引导 / 权限）共享的 chrome 安装器。
    /// 透明 titlebar + 隐藏交通灯 + shell 圆角 + 原生阴影 + 不释放即关，
    /// 收口前各处自行重复约 30 行配置；调用方仍保留窗口子类与 contentView 的控制权。
    func applyAuxiliaryChrome(_ window: NSWindow, title: String) {
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        // 隐藏交通灯，避免和 .fullSizeContentView 内容重叠
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { button in
            window.standardWindowButton(button)?.isHidden = true
        }
        // 通过 KVC 设置窗口圆角，让系统 frame 的裁切和 SwiftUI 内容的 shellCornerRadius 对齐
        window.setValue(ClipinChrome.cornerShell, forKey: "cornerRadius")
    }

    func openSettingsWindow(select tab: SettingsTab? = nil) {
        let window: NSWindow
        let isNew: Bool

        if let tab {
            settingsNavigation.select(tab)
        } else {
            settingsNavigation.ensureSelection()
        }

        if let existingWindow = settingsWindow {
            window = existingWindow
            isNew = false
        } else {
            let newWindow = ClipinSettingsWindow(
                contentRect: NSRect(origin: .zero, size: SettingsWindowMetrics.size),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            applyAuxiliaryChrome(newWindow, title: "Clipin Settings")
            newWindow.toolbarStyle = .preference
            newWindow.contentView = ClipinWindowHostingView(
                rootView: SettingsView(
                    settings: settings,
                    updateReminder: updateReminder,
                    autoBackup: autoBackupService,
                    cleanupService: cleanupService,
                    navigation: settingsNavigation,
                    core: appState.core
                )
            )
            settingsWindow = newWindow
            window = newWindow
            isNew = true
        }

        settings.refreshLaunchAtLoginStatus()
        if isNew { window.center() }  // 复用窗口时保留上次位置，符合 macOS 惯例
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func presentUpdateReminder(for release: ReleaseInfo) {
        let window: NSWindow

        if let existingWindow = updateReminderWindow {
            existingWindow.contentView = ClipinBorderlessHostingView(
                rootView: UpdateReminderView(
                    settings: settings,
                    release: release,
                    onLater: { [weak self] in self?.updateReminder.dismissActiveReminder() },
                    onViewRelease: { [weak self] in self?.updateReminder.openReleasePage() },
                    onDownload: { [weak self] in self?.updateReminder.downloadLatestRelease() }
                )
            )
            window = existingWindow
        } else {
            let newWindow = ClipinUpdateReminderPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.level = .statusBar
            newWindow.isFloatingPanel = true
            newWindow.hidesOnDeactivate = false
            newWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = ClipinBorderlessHostingView(
                rootView: UpdateReminderView(
                    settings: settings,
                    release: release,
                    onLater: { [weak self] in self?.updateReminder.dismissActiveReminder() },
                    onViewRelease: { [weak self] in self?.updateReminder.openReleasePage() },
                    onDownload: { [weak self] in self?.updateReminder.downloadLatestRelease() }
                )
            )
            newWindow.delegate = self
            updateReminderWindow = newWindow
            window = newWindow
        }

        positionUpdateReminderWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func dismissUpdateReminderWindow() {
        guard let updateReminderWindow else { return }
        let window = updateReminderWindow
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
                window.alphaValue = 1
            }
        })
    }

    func positionUpdateReminderWindow(_ window: NSWindow) {
        let size = window.frame.size
        if let button = statusItem?.button, let hostWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = hostWindow.convertToScreen(buttonFrameInWindow)
            let x = max(buttonFrameOnScreen.maxX - size.width, buttonFrameOnScreen.minX - 12)
            let y = buttonFrameOnScreen.minY - size.height - 10
            window.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let x = visible.maxX - size.width - 20
        let y = visible.maxY - size.height - 20
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func statusItemImage(hasPendingUpdate: Bool) -> NSImage? {
        let symbolName = hasPendingUpdate ? "clipboard.badge.exclamationmark" : "clipboard"
        let fallbackName = hasPendingUpdate ? "arrow.down.circle" : "clipboard"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clipin")
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: "Clipin")
        image?.isTemplate = true
        return image
    }

}
