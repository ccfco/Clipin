import XCTest
@testable import Clipin

final class ClipboardMonitorURLTests: XCTestCase {
    func testHTTPSURLIsRecognized() {
        XCTAssertEqual(ClipboardMonitor.httpURLString(in: "https://anthropic.com"), "https://anthropic.com")
    }

    func testHTTPURLIsRecognized() {
        XCTAssertEqual(ClipboardMonitor.httpURLString(in: "http://192.168.1.1:8080/x"), "http://192.168.1.1:8080/x")
    }

    func testPlainTextIsNotURL() {
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "just some text"))
    }

    func testNonHTTPSchemeIsRejected() {
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "ftp://example.com"))
        XCTAssertNil(ClipboardMonitor.httpURLString(in: "mailto:a@b.com"))
    }
}
