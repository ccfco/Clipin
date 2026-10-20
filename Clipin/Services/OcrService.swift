import Foundation
import Vision

/// 基于 Apple Vision Framework 的 OCR 服务
/// 支持中英文识别，accurate 模式，无第三方依赖
///
/// actor 串行化：accurate 模式单张图识别可达数百毫秒到数秒。新图片采集
/// （ClipboardMonitor）与历史 backfill（AppDelegate）是两条独立入口，若各自并发
/// 多个 Vision 请求，CPU 会被瞬时占满、内存峰值同步放大，拖慢前台渲染。
/// OCR 不在交互关键路径上，串行化只拉长批量图片的完成时间，换来可预期的资源占用。
actor OcrService {
    static let shared = OcrService()

    func recognizeText(at imagePath: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        // Vision 的 Swift 原生 API（macOS 15+）：ImageRequestHandler.perform 本身是
        // async，识别在框架内部线程执行，不再像 VNImageRequestHandler 那样同步占住
        // actor 的 executor。结果直接由返回值给出，没有 completion 双路径。
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "zh-Hant"),
            Locale.Language(identifier: "en-US"),
        ]

        let handler = ImageRequestHandler(url)
        do {
            let observations = try await handler.perform(request)
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        } catch {
            ClipinLog.ocr.error("OCR perform error: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }
}
