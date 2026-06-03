import XCTest
@testable import Clipin

final class ClipSectionBuilderTests: XCTestCase {
    private func item(id: String, createdAt: Int64, isPinned: Bool = false) -> ClipListItem {
        ClipListItem(
            id: id, preview: id, clipType: .text, sourceApp: nil, sourceName: nil,
            isPinned: isPinned, createdAt: createdAt, imagePath: nil, attachmentPaths: nil,
            charCount: 0, pasteCount: 0, copyCount: 0, imageWidth: nil, imageHeight: nil, alias: nil
        )
    }
    private func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    func testGroupsTodayYesterdayAndOlder() {
        let cal = Calendar.current
        let now = Date()
        let today = item(id: "t", createdAt: ms(now))
        let yesterday = item(id: "y", createdAt: ms(cal.date(byAdding: .day, value: -1, to: now)!))
        let older = item(id: "o", createdAt: ms(cal.date(byAdding: .day, value: -10, to: now)!))

        let sections = ClipSectionBuilder.build(items: [today, yesterday, older], showPinnedSection: false)

        XCTAssertEqual(sections.first?.title, NSLocalizedString("Today", comment: ""))
        XCTAssertEqual(sections.first?.items.map(\.id), ["t"])
        XCTAssertEqual(sections.dropFirst().first?.title, NSLocalizedString("Yesterday", comment: ""))
        XCTAssertEqual(sections.flatMap(\.items).count, 3)
    }

    func testPinnedSectionHoistedFirst() {
        let now = ms(Date())
        let pinned = item(id: "p", createdAt: now, isPinned: true)
        let regular = item(id: "r", createdAt: now)

        let sections = ClipSectionBuilder.build(items: [pinned, regular], showPinnedSection: true)

        XCTAssertEqual(sections.first?.title, NSLocalizedString("Pinned", comment: ""))
        XCTAssertEqual(sections.first?.items.map(\.id), ["p"])
        XCTAssertTrue(sections.dropFirst().flatMap(\.items).map(\.id).contains("r"))
    }

    func testPinnedSectionSuppressedWhenFlagOff() {
        let now = ms(Date())
        let pinned = item(id: "p", createdAt: now, isPinned: true)
        let sections = ClipSectionBuilder.build(items: [pinned], showPinnedSection: false)
        XCTAssertNotEqual(sections.first?.title, NSLocalizedString("Pinned", comment: ""))
        XCTAssertEqual(sections.flatMap(\.items).map(\.id), ["p"])
    }

    func testEmptyInputYieldsNoSections() {
        XCTAssertTrue(ClipSectionBuilder.build(items: [], showPinnedSection: true).isEmpty)
    }
}
