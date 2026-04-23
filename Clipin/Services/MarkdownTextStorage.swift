import AppKit

/// `NSTextStorage` 子类：在编辑时自动为 Markdown 文本应用所见即所得样式。
/// 关闭 WYSIWYM 时表现为纯文本，打开时实时渲染标题/粗体/斜体/代码等样式。
final class MarkdownTextStorage: NSTextStorage {

    private let backingStore = NSMutableAttributedString()
    private var isProcessing = false

    /// 是否启用 Markdown 所见即所得样式
    var isWysiwygMode: Bool = false {
        didSet { applyStyles() }
    }

    // MARK: - NSTextStorage 抽象方法

    override var string: String { backingStore.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        backingStore.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backingStore.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        beginEditing()
        backingStore.replaceCharacters(in: range, with: attrString)
        edited(.editedCharacters, range: range, changeInLength: attrString.length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backingStore.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: - 样式应用

    override func processEditing() {
        // 如果正在应用样式，不再递归触发
        if isProcessing {
            super.processEditing()
            return
        }

        // 如果不是 WYSIWYM 模式，不处理
        if !isWysiwygMode {
            super.processEditing()
            return
        }

        // 防止在 applyStyles 中触发二次 processEditing
        isProcessing = true
        applyStyles()
        isProcessing = false

        super.processEditing()
    }

    /// 重新对整个内容应用 Markdown 样式
    func applyStyles() {
        guard isWysiwygMode else {
            // 关闭时去掉所有自定义属性，回归纯文本（textView 会使用默认等宽字体）
            if backingStore.length > 0 {
                beginEditing()
                backingStore.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: backingStore.length))
                backingStore.removeAttribute(.font, range: NSRange(location: 0, length: backingStore.length))
                backingStore.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: backingStore.length))
                backingStore.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: backingStore.length))
                endEditing()
                edited(.editedAttributes, range: NSRange(location: 0, length: backingStore.length), changeInLength: 0)
            }
            return
        }

        // 对整个内容重新应用样式
        let plainText = backingStore.string
        let styled = MarkdownAttributedRenderer.render(plainText)

        beginEditing()
        backingStore.replaceCharacters(in: NSRange(location: 0, length: backingStore.length), with: styled)
        endEditing()
        edited(.editedCharacters, range: NSRange(location: 0, length: backingStore.length), changeInLength: 0)
    }
}
