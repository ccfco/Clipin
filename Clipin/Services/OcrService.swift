import Vision

/// 基于 Apple Vision Framework 的 OCR 服务
/// 支持中英文识别，accurate 模式，无第三方依赖
enum OcrService {
    static func recognizeText(at imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // VNImageRequestHandler.perform 是同步调用；这里直接在返回后读取 results，
        // 避免 completion + catch 两条路径重复 resume continuation 导致 OCR 后台线程崩溃。
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("⚠️ OCR perform error: \(error)")
            return ""
        }

        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            ?? ""
    }
}
