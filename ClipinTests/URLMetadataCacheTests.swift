import XCTest
@testable import Clipin

final class URLMetadataCacheTests: XCTestCase {
    func testHTMLPrefixRequestUsesBrowserHeadersWithoutCrawlerFingerprint() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))

        let request = URLMetadataCache.makeHTMLPrefixRequest(for: url)

        // 不再发 Range / 手动 Accept-Encoding —— 让 URLSession 自动 gzip+解压，
        // 且去掉爬虫/下载器指纹（真实浏览器加载文档不发这两个头）。
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept-Encoding"))
        // 真实 Safari UA（带 Version/ 段）+ 完整文档请求头。
        let ua = try XCTUnwrap(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertTrue(ua.contains("Safari"))
        XCTAssertTrue(ua.contains("Version/"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Accept-Language"))
    }

    func testDirectImageResourceMatchesImageExtensions() throws {
        for path in ["https://cdn.site.com/a.png", "https://x.com/photo.JPG",
                     "https://x.com/a.png?v=2", "https://x.com/share.webp",
                     "https://x.com/pic.gif", "https://x.com/vector.svg"] {
            let url = try XCTUnwrap(URL(string: path))
            XCTAssertTrue(URLMetadataCache.isDirectImageResource(url), "应识别为图片直链: \(path)")
        }
    }

    func testDirectImageResourceRejectsNonImageURLs() throws {
        // arxiv PDF 的版本号 .13245 不是图片格式；ico/无扩展名/HTML 页面都不算预览大图。
        for path in ["https://arxiv.org/pdf/2305.13245", "https://github.com/a/b",
                     "https://x.com/favicon.ico", "https://x.com/doc.pdf",
                     "https://example.com/"] {
            let url = try XCTUnwrap(URL(string: path))
            XCTAssertFalse(URLMetadataCache.isDirectImageResource(url), "不应识别为图片直链: \(path)")
        }
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
