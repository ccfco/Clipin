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

    func testWriteToClipboardDoesNotClearExistingClipboardWhenFileIsMissing() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        let missingFile = ClipItem(
            id: "missing-file",
            content: "/tmp/clipin-missing-file-\(UUID().uuidString)",
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

        XCTAssertFalse(PasteService.writeToClipboard(missingFile))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testWriteToClipboardDoesNotPartiallyWriteFileSelections() throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipinPasteServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.txt")
        try "ok".write(to: existing, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing.txt")

        let partialSelection = ClipItem(
            id: "partial-file-selection",
            content: FileClipboardContent.encodedContent(from: [existing.path, missing.path]),
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

        XCTAssertFalse(PasteService.writeToClipboard(partialSelection))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }
}
