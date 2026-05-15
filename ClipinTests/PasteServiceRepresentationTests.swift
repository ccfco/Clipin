import XCTest
import AppKit
@testable import Clipin

final class PasteServiceRepresentationTests: XCTestCase {
    private func makeItem(content: String, clipType: ClipType) -> ClipItem {
        ClipItem(
            id: UUID().uuidString,
            content: content,
            clipType: clipType,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            charCount: Int32(content.count),
            copyCount: 0,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0
        )
    }

    func testWriteAllRepresentationsSetsAllUTIs() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()

        let item = makeItem(content: "hi", clipType: .text)
        let reps: [ClipRepresentation] = [
            ClipRepresentation(uti: "public.html", data: Data("<p>hi</p>".utf8)),
            ClipRepresentation(uti: "public.rtf",  data: Data("{\\rtf1 hi}".utf8)),
        ]

        let ok = PasteService.writeAllRepresentations(item, representations: reps, to: pb)
        XCTAssertTrue(ok)

        XCTAssertEqual(pb.string(forType: .string), "hi")
        XCTAssertEqual(pb.data(forType: .html), Data("<p>hi</p>".utf8))
        XCTAssertEqual(pb.data(forType: .rtf), Data("{\\rtf1 hi}".utf8))
    }

    func testWriteAllRepresentationsFallsBackWhenEmpty() {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: "test-\(UUID().uuidString)"))
        pb.clearContents()

        let item = makeItem(content: "hi", clipType: .text)
        let ok = PasteService.writeAllRepresentations(item, representations: [], to: pb)

        XCTAssertTrue(ok)
        XCTAssertEqual(pb.string(forType: .string), "hi")
        XCTAssertNil(pb.data(forType: .html))
    }
}
