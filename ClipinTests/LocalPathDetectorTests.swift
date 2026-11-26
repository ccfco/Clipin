import XCTest
@testable import Clipin

final class LocalPathDetectorTests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots.removeAll()
        try super.tearDownWithError()
    }

    func testLooksLikeSingleLocalPath() {
        XCTAssertTrue(LocalPathDetector.looksLikeSingleLocalPath("/Users/test/Desktop"))
        XCTAssertTrue(LocalPathDetector.looksLikeSingleLocalPath("  ~/Documents/notes  \n"))
        XCTAssertTrue(LocalPathDetector.looksLikeSingleLocalPath("\"/Users/test/My Folder\""))
        XCTAssertTrue(LocalPathDetector.looksLikeSingleLocalPath("'~/Work/Clipin'"))

        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath(""))
        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath("/"))
        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath("//network/share"))
        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath("https://example.com/Users/foo"))
        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath("./relative/path"))
        XCTAssertFalse(LocalPathDetector.looksLikeSingleLocalPath("/Users/a\n/Users/b"))
    }

    func testResolveSinglePathDistinguishesFolderFileAndAppPackage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPathDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)

        let folderWithSpaces = root.appendingPathComponent("My Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderWithSpaces, withIntermediateDirectories: true)

        let regularFile = root.appendingPathComponent("sample.txt")
        try "hello".write(to: regularFile, atomically: true, encoding: .utf8)

        // `.app` bundles are directories on disk, but must NOT be treated as openable folders
        // (calling NSWorkspace.open on a package launches the app instead of revealing in Finder).
        let fakeAppBundle = root.appendingPathComponent("Sample.app", isDirectory: true)
        let contentsDir = fakeAppBundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """.write(to: contentsDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let quotedFolder = "\"\(folderWithSpaces.path)\""
        let resolvedFolder = try XCTUnwrap(LocalPathDetector.resolveSinglePath(from: quotedFolder))
        XCTAssertTrue(resolvedFolder.isDirectory)
        XCTAssertEqual(resolvedFolder.url.standardizedFileURL.path, folderWithSpaces.standardizedFileURL.path)

        let resolvedFile = try XCTUnwrap(LocalPathDetector.resolveSinglePath(from: regularFile.path))
        XCTAssertFalse(resolvedFile.isDirectory)
        XCTAssertEqual(resolvedFile.url.standardizedFileURL.path, regularFile.standardizedFileURL.path)

        let resolvedApp = try XCTUnwrap(LocalPathDetector.resolveSinglePath(from: fakeAppBundle.path))
        XCTAssertFalse(resolvedApp.isDirectory)

        XCTAssertNil(LocalPathDetector.resolveSinglePath(from: root.appendingPathComponent("missing").path))
    }

    func testExtractInlineCandidatesExcludesURLsAndTrimsPunctuation() throws {
        let text = """
        Visit https://example.com/Users/ignored/path first.
        Open /Users/alice/Project, or "~/My Docs/report.md"; fallback is /tmp/out.log!
        """
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsText = text as NSString
        let urlRanges = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).map(\.range)

        let candidates = LocalPathDetector.extractInlineCandidates(in: text, excluding: urlRanges)
        let paths = candidates.map(\.rawPath)

        XCTAssertEqual(paths, [
            "/Users/alice/Project",
            "~/My Docs/report.md",
            "/tmp/out.log"
        ])
    }

    func testExtractInlineCandidatesHandlesUnquotedSpacesPerLineAndTldFolders() throws {
        let text = """
        /Users/alice/My Folder
        /Users/alice/project.io
        Visit https://example.com/Users/ignored/path
        """
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let nsText = text as NSString
        let explicitSchemeRanges = detector
            .matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            .compactMap { match -> NSRange? in
                let sub = nsText.substring(with: match.range).lowercased()
                return (sub.contains("://") || sub.hasPrefix("mailto:")) ? match.range : nil
            }

        let candidates = LocalPathDetector.extractInlineCandidates(in: text, excluding: explicitSchemeRanges)
        XCTAssertEqual(candidates.map(\.rawPath), [
            "/Users/alice/My Folder",
            "/Users/alice/project.io"
        ])
    }
}
