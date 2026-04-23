import AppKit

/// 轻量 Markdown 所见即所得编辑：用 NSLayoutManager 临时属性实现语法高亮。
///
/// 调研结论（Apple 官方推荐）：
/// - 不要在 NSTextStorage.processEditing() 中修改属性（会导致光标跳动、内容丢失）
/// - 正确方案：用 NSLayoutManager.setTemporaryAttributes() 仅影响视觉渲染，不触发递归
/// - 参考：WWDC 2018 TextKit 最佳实践、STTextView/Neon 等开源编辑器实现
final class MarkdownStyleApplier {

    private weak var layoutManager: NSLayoutManager?
    private weak var textStorage: NSTextStorage?
    private var styleTimer: DispatchSourceTimer?

    var isWysiwygMode: Bool = false {
        didSet {
            if isWysiwygMode { applyStyles() } else { clearStyles() }
        }
    }

    init(layoutManager: NSLayoutManager, textStorage: NSTextStorage) {
        self.layoutManager = layoutManager
        self.textStorage = textStorage
    }

    /// 内容变化后调用，延迟 150ms 后应用临时样式
    func contentDidChange() {
        guard isWysiwygMode else { return }
        scheduleStyleUpdate()
    }

    private func scheduleStyleUpdate() {
        styleTimer?.cancel()
        styleTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .milliseconds(150))
        timer.setEventHandler { [weak self] in
            self?.applyStyles()
        }
        timer.resume()
        styleTimer = timer
    }

    private func applyStyles() {
        styleTimer = nil
        guard let layoutManager, let storage = textStorage,
              isWysiwygMode, storage.length > 0 else { return }

        let styled = MarkdownAttributedRenderer.render(storage.string)
        let totalLength = storage.length

        // 先清除所有旧的临时属性（逐个 key 移除）
        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .paragraphStyle, .strikethroughStyle, .strikethroughColor, .underlineStyle]
        for key in keys {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: NSRange(location: 0, length: totalLength))
        }

        // 应用新的临时属性
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
            guard range.length > 0, range.location + range.length <= totalLength else { return }
            layoutManager.setTemporaryAttributes(attrs, forCharacterRange: range)
        }
    }

    func clearStyles() {
        styleTimer?.cancel()
        styleTimer = nil
        guard let layoutManager, let storage = textStorage, storage.length > 0 else { return }

        let keys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .paragraphStyle, .strikethroughStyle, .strikethroughColor, .underlineStyle]
        for key in keys {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: NSRange(location: 0, length: storage.length))
        }
    }
}
