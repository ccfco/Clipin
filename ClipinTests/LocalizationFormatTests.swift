import XCTest

final class LocalizationFormatTests: XCTestCase {
    func testChineseImportArchiveNoticeUsesPositionalFormatSpecifiers() throws {
        let strings = try localizedStrings(for: "zh-Hans")
        let format = try XCTUnwrap(strings["Imported %d items from %@."] as? String)

        XCTAssertTrue(format.contains("%1$d"))
        XCTAssertTrue(format.contains("%2$@"))
        XCTAssertEqual(String(format: format, 3, "backup.json"), "已从 backup.json 导入 3 项。")
    }

    private func localizedStrings(for localization: String) throws -> NSDictionary {
        let bundleURL = try XCTUnwrap(Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ))
        return try XCTUnwrap(NSDictionary(contentsOf: bundleURL))
    }
}
