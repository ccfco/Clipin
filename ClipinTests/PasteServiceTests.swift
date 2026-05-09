import AppKit
import XCTest
@testable import Clipin

final class PasteServiceTests: XCTestCase {
    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    func testWriteToClipboardDoesNotClearExistingClipboardWhenImageIsMissing() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        let missingImage = ClipItem(
            id: "missing-image",
            content: "image",
            clipType: .image,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: "/tmp/clipin-missing-image-\(UUID().uuidString).png",
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0
        )

        XCTAssertFalse(PasteService.writeToClipboard(missingImage))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testWritePlainTextDoesNotClearExistingClipboardWhenFileSelectionIsEmpty() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        let emptyFileSelection = ClipItem(
            id: "empty-file",
            content: "",
            clipType: .file,
            sourceApp: nil,
            sourceName: nil,
            isPinned: false,
            createdAt: 0,
            imagePath: nil,
            charCount: 0,
            copyCount: 1,
            firstCopiedAt: 0,
            ocrText: nil,
            pasteCount: 0
        )

        XCTAssertFalse(PasteService.writeAsPlainText(emptyFileSelection))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }
}
