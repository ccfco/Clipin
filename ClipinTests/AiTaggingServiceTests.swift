import XCTest
@testable import Clipin

final class AiTaggingServiceTests: XCTestCase {

    func testSanitizeTrimsDedupesAndCaps() {
        let tags = AiTaggingService.sanitize([
            "  invoice ",
            "Invoice",          // 大小写去重
            "#receipt",
            "budget, planning", // 同行多标签必须拆开，与预览 rail 粒度一致
            "",
            "   ",
            String(repeating: "x", count: 41),  // 超长丢弃
            "a\nb",             // 换行丢弃
            "one", "two", "three", "four",
        ])
        XCTAssertEqual(tags, ["invoice", "receipt", "budget", "planning", "one"])
        XCTAssertFalse(tags.contains { $0.contains("x") })
    }

    func testTaggingInputIncludesAlias() {
        let input = AiTaggingService.taggingInput(alias: "报销", text: "invoice total 128")
        XCTAssertTrue(input.contains("报销"))
        XCTAssertTrue(input.contains("invoice total 128"))
    }

    func testTaggingInputIsCapped() {
        let long = String(repeating: "字", count: 5_000)
        XCTAssertEqual(AiTaggingService.taggingInput(alias: nil, text: long).count, 2_000)
    }
}
