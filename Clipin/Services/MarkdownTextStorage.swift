import AppKit

/// `NSTextStorage` 子类：在编辑时自动为 Markdown 文本应用所见即所得样式。
///
/// 实现策略：用 debounce 延迟应用样式，避免每次编辑都触发重算。
/// 使用 DispatchQueue.main.asyncAfter 实现防抖，200ms 后原地更新属性。
final class MarkdownTextStorage: NSTextStorage {

    private let backingStore = NSMutableAttributedString()
    private var lastStyledContent: String?
    private var styleTimer: DispatchSourceTimer?

    /// 是否启用 Markdown 所见即所得样式
    var isWysiwygMode: Bool = false {
        didSet {
            if isWysiwygMode {
                applyStylesSync()
            } else {
                clearStyles()
            }
        }
    }

    // MARK: - NSTextStorage 抽象方法

    override var string: String { backingStore.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backingStore.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backingStore.replaceCharacters(in: range, with: str)
        endEditing()
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
    }

    override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        beginEditing()
        backingStore.replaceCharacters(in: range, with: attrString)
        endEditing()
        edited(.editedCharacters, range: range, changeInLength: attrString.length - range.length)
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        backingStore.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }

    // MARK: - 样式应用

    override func processEditing() {
        if !isWysiwygMode {
            super.processEditing()
            return
        }

        super.processEditing()

        // 内容变化时才需要重新样式化
        if backingStore.string != lastStyledContent {
            scheduleStyleUpdate()
        }
    }

    /// 200ms debounce 防抖，防止连续输入时频繁重算
    private func scheduleStyleUpdate() {
        styleTimer?.cancel()
        styleTimer = nil

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.applyStylesInPlace()
        }
        timer.resume()
        styleTimer = timer
    }

    /// 原地应用属性（只改属性不改文字），光标位置不受影响
    private func applyStylesInPlace() {
        styleTimer = nil
        guard isWysiwygMode, backingStore.length > 0 else { return }

        let styled = MarkdownAttributedRenderer.render(backingStore.string)

        beginEditing()
        styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attrs, range, _ in
            backingStore.setAttributes(attrs, range: range)
        }
        endEditing()

        // 只通知属性变化，光标不移动
        edited(.editedAttributes, range: NSRange(location: 0, length: backingStore.length), changeInLength: 0)

        lastStyledContent = backingStore.string
    }

    /// 同步应用样式（用于模式切换）
    private func applyStylesSync() {
        styleTimer?.cancel()
        styleTimer = nil
        applyStylesInPlace()
    }

    /// 关闭 WYSIWYM 时去掉所有自定义属性
    private func clearStyles() {
        styleTimer?.cancel()
        styleTimer = nil
        guard backingStore.length > 0 else { return }

        beginEditing()
        backingStore.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: backingStore.length))
        backingStore.removeAttribute(.font, range: NSRange(location: 0, length: backingStore.length))
        backingStore.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: backingStore.length))
        backingStore.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: backingStore.length))
        endEditing()
        edited(.editedAttributes, range: NSRange(location: 0, length: backingStore.length), changeInLength: 0)
        lastStyledContent = nil
    }

    /// 外部调用：强制重新应用样式
    func applyStyles() {
        if isWysiwygMode {
            applyStylesSync()
        } else {
            clearStyles()
        }
    }
}
