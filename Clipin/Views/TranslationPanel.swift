import SwiftUI
@preconcurrency import Translation
import NaturalLanguage
import os

/// 剪贴板条目的翻译面板（Translation framework，系统本机/端侧能力）。
///
/// 生命周期：动作面板执行 Translate → AppDelegate 打开此窗口 → 视图出现时识别源语言并
/// 设置 `TranslationSession.Configuration`，由 `.translationTask` 提供会话。
/// 语言对未安装时 `prepareTranslation()` 会走系统下载流程（系统自有 UI，不自绘）。
struct TranslationPanelView: View {
    let item: ClipItem

    /// 翻译长文本代价高且没有实际收益：正文/OCR 都截断到 5000 字符，并显式告知用户。
    private static let maxCharacters = 5_000

    @State private var sourceText = ""
    @State private var isTruncated = false
    @State private var sourceLanguage: Locale.Language?
    @State private var targetLanguage: Locale.Language?
    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var errorMessage: String?
    @State private var isTranslating = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: ClipinChrome.groupGap) {
                    section(title: "Original", text: sourceText)

                    Divider()

                    resultSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(ClipinChrome.edge)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear(perform: prepare)
        .translationTask(configuration) { session in
            // TranslationSession 非 Sendable：整个翻译过程留在当前非隔离上下文，
            // 只把 String 结果 hop 回 MainActor 更新 UI。
            let text = await MainActor.run { sourceText }
            await MainActor.run { isTranslating = true }
            do {
                try await session.prepareTranslation()
                let response = try await session.translate(text)
                await MainActor.run {
                    translatedText = response.targetText
                    isTranslating = false
                }
            } catch {
                ClipinLog.app.error("Translation failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    errorMessage = NSLocalizedString("Translation failed. Check that the language pair is available in System Settings.", comment: "")
                    isTranslating = false
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: ClipinChrome.gap) {
            Image(systemName: "translate")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)
            Text(languagePairLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ClipinInk.secondary)
            Spacer(minLength: 0)
            if isTruncated {
                Text("Showing first 5,000 characters")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipinInk.secondary)
            }
        }
    }

    private func section(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ClipinInk.secondary)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        VStack(alignment: .leading, spacing: ClipinChrome.gap) {
            HStack(spacing: ClipinChrome.gap) {
                Text("Translation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClipinInk.secondary)
                Spacer(minLength: 0)
                if translatedText != nil {
                    Button(didCopy ? "Copied" : "Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(translatedText ?? "", forType: .string)
                        didCopy = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.2))
                            didCopy = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if let translatedText {
                Text(translatedText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isTranslating {
                HStack(spacing: ClipinChrome.gap) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.system(size: 12))
                        .foregroundStyle(ClipinInk.secondary)
                }
            }
        }
    }

    private var languagePairLabel: String {
        let source = sourceLanguage.map(Self.displayName) ?? NSLocalizedString("Auto-detect", comment: "")
        let target = targetLanguage.map(Self.displayName) ?? NSLocalizedString("System language", comment: "")
        return "\(source) → \(target)"
    }

    private static func displayName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
            ?? language.maximalIdentifier
    }

    // MARK: - Flow

    private func prepare() {
        // 图片翻译 OCR 文本；text/url 翻译正文。file 类型是路径 JSON，没有翻译价值。
        let raw: String
        switch item.clipType {
        case .image: raw = item.ocrText ?? ""
        default: raw = item.content
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = NSLocalizedString("There is no text to translate.", comment: "")
            return
        }
        isTruncated = raw.count > Self.maxCharacters
        sourceText = String(raw.prefix(Self.maxCharacters))

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sourceText)
        guard let detected = recognizer.dominantLanguage else {
            errorMessage = NSLocalizedString("Couldn't detect the source language.", comment: "")
            return
        }

        let source = Locale.Language(identifier: detected.rawValue)
        sourceLanguage = source
        let target = Self.resolveTarget(for: source)
        targetLanguage = target
        configuration = TranslationSession.Configuration(source: source, target: target)
    }

    /// 目标语言：默认跟随系统语言；源语言恰好等于系统语言时切到另一常用语言，
    /// 避免"翻译成同一种语言"这种无意义结果。
    private static func resolveTarget(for source: Locale.Language) -> Locale.Language {
        let system = Locale.current.language
        let systemCode = system.languageCode?.identifier
        if source.languageCode?.identifier != systemCode {
            return system
        }
        let alternative = systemCode == "zh" ? "en" : "zh-Hans"
        return Locale.Language(identifier: alternative)
    }
}
