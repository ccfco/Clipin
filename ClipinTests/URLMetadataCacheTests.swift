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

    func testExtractOGImageAcceptsTwitterPropertyImage() throws {
        let html = """
        <html><head>
        <meta property="twitter:image" content="/cards/twitter.png">
        </head><body></body></html>
        """
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/posts/1"))

        let imageURL = URLMetadataCache.extractOGImageURL(in: html, baseURL: baseURL)

        XCTAssertEqual(imageURL, "https://example.com/cards/twitter.png")
    }

    func testExtractOGImageAcceptsImageSrcLink() throws {
        let html = """
        <html><head>
        <link rel="image_src" href="/legacy/share.png">
        </head><body></body></html>
        """
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/posts/1"))

        let imageURL = URLMetadataCache.extractOGImageURL(in: html, baseURL: baseURL)

        XCTAssertEqual(imageURL, "https://example.com/legacy/share.png")
    }

    func testAutoFetchPolicyAllowsLocalHosts() throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:8810/report.html"))

        XCTAssertTrue(URLMetadataCache.shouldAutoFetchMetadata(for: url))
    }

    func testAutoFetchPolicyAllowsPrivateLANHosts() throws {
        let url = try XCTUnwrap(URL(string: "http://192.168.1.20:9210/login"))

        XCTAssertTrue(URLMetadataCache.shouldAutoFetchMetadata(for: url))
    }

    func testAutoFetchPolicySkipsTokenAndWebhookURLs() throws {
        let magicLink = try XCTUnwrap(URL(string: "https://example.com/login?token=one-shot"))
        let webhook = try XCTUnwrap(URL(string: "https://example.com/api/webhook/build"))

        XCTAssertFalse(URLMetadataCache.shouldAutoFetchMetadata(for: magicLink))
        XCTAssertFalse(URLMetadataCache.shouldAutoFetchMetadata(for: webhook))
    }

    func testExtractOGImageAllowsLocalURL() throws {
        let html = """
        <html><head>
        <meta property="og:image" content="http://localhost:8810/share-card.png">
        </head><body></body></html>
        """
        let baseURL = try XCTUnwrap(URL(string: "http://localhost:8810/report.html"))

        let imageURL = URLMetadataCache.extractOGImageURL(in: html, baseURL: baseURL)

        XCTAssertEqual(imageURL, "http://localhost:8810/share-card.png")
    }

    func testExtractOGImageSkipsWebhookURL() throws {
        let html = """
        <html><head>
        <meta property="og:image" content="https://example.com/webhook/share-card.png">
        </head><body></body></html>
        """
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/report.html"))

        let imageURL = URLMetadataCache.extractOGImageURL(in: html, baseURL: baseURL)

        XCTAssertNil(imageURL)
    }
}
