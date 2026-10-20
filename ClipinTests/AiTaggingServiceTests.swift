import XCTest
@testable import Clipin

final class AiTaggingServiceTests: XCTestCase {

    func testSanitizeTrimsDedupesAndCaps() {
        let tags = AiTaggingService.sanitize([
            "  invoice ",
            "Invoice",          // 大小写去重
            "#receipt",
            "budget, planning",
            "",
            "   ",
            String(repeating: "x", count: 41),  // 超长丢弃
            "a\nb",             // 换行丢弃
            "one", "two", "three", "four",
        ])
        XCTAssertEqual(tags.count, 5)
        XCTAssertEqual(Array(tags.prefix(3)), ["invoice", "receipt", "budget, planning"])
        XCTAssertFalse(tags.contains { $0.contains("x") })
    }

    func testTaggingInputUsesOCRForImagesAndIncludesAlias() {
        let image = ClipItem(
            id: "img",
            content: "image",
            clipType: .image,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: "/tmp/x.png",
            attachmentPaths: nil,
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: "invoice total 128",
            pasteCount: 0,
            alias: "报销",
            aiTags: nil
        )
        let input = AiTaggingService.taggingInput(for: image)
        XCTAssertTrue(input.contains("报销"))
        XCTAssertTrue(input.contains("invoice total 128"))
        // 图片占位 content 不能喂给模型，否则每张图都会得到 "image" 类噪声标签
        XCTAssertFalse(input.contains("\nimage"))
    }

    func testTaggingInputIsCapped() {
        let long = String(repeating: "字", count: 5_000)
        let item = ClipItem(
            id: "txt",
            content: long,
            clipType: .text,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            attachmentPaths: nil,
            charCount: 5_000,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0,
            alias: nil,
            aiTags: nil
        )
        XCTAssertEqual(AiTaggingService.taggingInput(for: item).count, 2_000)
    }
}
