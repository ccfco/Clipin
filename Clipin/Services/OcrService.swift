import Vision

/// 基于 Apple Vision Framework 的 OCR 服务
/// 支持中英文识别，accurate 模式，无第三方依赖
enum OcrService {
    static func recognizeText(at imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        return await withCheckedContinuation { continuation in
            // completion handler 中处理 OCR 错误，保证 continuation 一定被 resume
            // perform 失败时 completion 不会被调用，所以错误必须在 do/catch 里 resume
            let request = VNRecognizeTextRequest { req, error in
                if let error {
                    print("⚠️ OCR request error: \(error)")
                    continuation.resume(returning: "")
                    return
                }
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
                print("⚠️ OCR: failed to create handler for \(imagePath)")
                continuation.resume(returning: "")
                return
            }
            do {
                try handler.perform([request])
            } catch {
                // perform 抛出时 completion 不被调用，必须在此 resume 兜底
                print("⚠️ OCR perform error: \(error)")
                continuation.resume(returning: "")
            }
        }
    }
}
