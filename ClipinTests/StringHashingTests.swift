import XCTest
@testable import Clipin

final class StringHashingTests: XCTestCase {
    /// 同一字符串必须得到稳定哈希——磁盘缓存文件名/host 配色都依赖跨调用一致。
    func testDeterministicForSameInput() {
        XCTAssertEqual("https://github.com/foo".fnv1aHash(), "https://github.com/foo".fnv1aHash())
        XCTAssertEqual("".fnv1aHash(), "".fnv1aHash())
    }

    /// 不同输入哈希应不同（FNV-1a 分布够散，常见字符串不撞）。
    func testDistinctForDifferentInput() {
        XCTAssertNotEqual("github.com".fnv1aHash(), "gitlab.com".fnv1aHash())
        XCTAssertNotEqual("a".fnv1aHash(), "b".fnv1aHash())
    }

    /// 锚定 FNV-1a 标准向量：空串 = offset basis，"a" = basis ^ 0x61 * prime。
    /// 锁死算法常量，防有人误改 offset/prime 导致已有磁盘缓存文件名集体失配。
    func testKnownVectors() {
        XCTAssertEqual("".fnv1aHash(), 0xcbf29ce484222325)
        XCTAssertEqual("a".fnv1aHash(), 0xaf63dc4c8601ec8c)
    }
}
