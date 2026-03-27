import Vision

/// 基于 Apple Vision Framework 的 OCR 服务
/// 支持中英文识别，accurate 模式，无第三方依赖
enum OcrService {
    static func recognizeText(at imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let text = (req.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                    ?? ""
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // 中文在前，优先中文识别；英文兜底
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            guard let handler = try? VNImageRequestHandler(url: url, options: [:]) else {
                continuation.resume(returning: "")
                return
            }
            try? handler.perform([request])
        }
    }
}
