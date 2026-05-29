import XCTest
@testable import Clipin

final class URLMetadataCacheTests: XCTestCase {
    func testHTMLPrefixRequestDisablesCompressionWhenUsingRange() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))

        let request = URLMetadataCache.makeHTMLPrefixRequest(for: url)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-65535")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testExtractOGImageAcceptsSecureURL() throws {
        let html = """
        <html><head>
        <meta property="og:image:secure_url" content="/assets/share-card.png">
        </head><body></body></html>
        """
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/posts/1"))

        let imageURL = URLMetadataCache.extractOGImageURL(in: html, baseURL: baseURL)

        XCTAssertEqual(imageURL, "https://example.com/assets/share-card.png")
    }
}
