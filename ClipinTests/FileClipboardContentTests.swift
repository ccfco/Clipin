import XCTest
@testable import Clipin

final class FileClipboardContentTests: XCTestCase {
    func testEncodedContentDropsEmptyPathsAndRoundTripsMultipleFiles() {
        let content = FileClipboardContent.encodedContent(from: [
            " /Users/me/Desktop/a.txt ",
            "",
            "/Users/me/Desktop/b.txt\n",
        ])

        XCTAssertEqual(content, "/Users/me/Desktop/a.txt\n/Users/me/Desktop/b.txt")
        XCTAssertEqual(
            FileClipboardContent.paths(from: content),
            ["/Users/me/Desktop/a.txt", "/Users/me/Desktop/b.txt"]
        )
    }

    func testPathsKeepWholeFileSelectionContext() {
        let content = FileClipboardContent.encodedContent(from: [
            "/Users/me/Desktop/a.txt",
            "/Users/me/Desktop/b.txt",
            "/Users/me/Desktop/c.txt",
        ])

        XCTAssertEqual(FileClipboardContent.paths(from: content).count, 3)
        XCTAssertEqual(FileClipboardContent.displayName(for: "/Users/me/Desktop/a.txt"), "a.txt")
    }
}
