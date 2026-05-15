import XCTest
import AppKit
@testable import Clipin

final class ClipboardRepresentationTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testExtractsHTMLAndRTF() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        pb.setData(Data("<p>hi</p>".utf8), forType: .html)
        pb.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 2)
        XCTAssertTrue(reps.contains { $0.uti == "public.html" })
        XCTAssertTrue(reps.contains { $0.uti == "public.rtf" })
    }

    func testSkipsRedundantPublicURLForPlainURL() {
        // 当 plain text 完全等于 public.url，去重应跳过 public.url
        let pb = makePasteboard()
        let url = "https://example.com"
        pb.setString(url, forType: .string)
        pb.setString(url, forType: .URL)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: url)
        XCTAssertEqual(reps.count, 0)
    }

    func testSkipsBlacklistedDynamicUTIs() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        pb.setData(Data([0xDE, 0xAD]), forType: NSPasteboard.PasteboardType("dyn.private"))
        pb.setData(Data([0xBE, 0xEF]), forType: NSPasteboard.PasteboardType("com.apple.NSColor.pasteboard"))

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 0)
    }

    func testFallbackWhenTotalSizeExceedsLimit() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        // 5 MB 超过 4 MB 总和上限
        let big = Data(count: 5 * 1024 * 1024)
        pb.setData(big, forType: .html)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 0, "Total > 4MB should fallback to plain only")
    }

    func testSkipsOversizedSingleRepresentation() {
        let pb = makePasteboard()
        pb.setString("hi", forType: .string)
        let big = Data(count: 2 * 1024 * 1024)  // 2MB > 1MB single limit
        pb.setData(big, forType: .html)
        let small = Data("{\\rtf1 hi}".utf8)
        pb.setData(small, forType: .rtf)

        let reps = ClipboardRepresentationExtractor.extract(from: pb, primaryContent: "hi")
        XCTAssertEqual(reps.count, 1)
        XCTAssertEqual(reps[0].uti, "public.rtf")
    }
}
