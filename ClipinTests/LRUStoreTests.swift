import XCTest
@testable import Clipin

final class LRUStoreTests: XCTestCase {
    func testGetReturnsStoredValue() {
        var store = LRUStore<String, Int>()
        store.set("a", 1, maxEntries: 3)
        XCTAssertEqual(store.get("a"), 1)
        XCTAssertNil(store.get("missing"))
    }

    /// 超上限时淘汰最久未访问者。
    func testEvictsLeastRecentlyUsed() {
        var store = LRUStore<String, Int>()
        store.set("a", 1, maxEntries: 2)
        store.set("b", 2, maxEntries: 2)
        store.set("c", 3, maxEntries: 2)  // 触发淘汰，"a" 最久未用应被逐出
        XCTAssertNil(store.get("a"))
        XCTAssertEqual(store.get("b"), 2)
        XCTAssertEqual(store.get("c"), 3)
        XCTAssertEqual(store.count, 2)
    }

    /// get 触达后该 key 变为最近，下次淘汰应轮到别人。
    func testGetRefreshesRecency() {
        var store = LRUStore<String, Int>()
        store.set("a", 1, maxEntries: 2)
        store.set("b", 2, maxEntries: 2)
        _ = store.get("a")               // "a" 重新变最近
        store.set("c", 3, maxEntries: 2)  // 该淘汰 "b"
        XCTAssertEqual(store.get("a"), 1)
        XCTAssertNil(store.get("b"))
        XCTAssertEqual(store.get("c"), 3)
    }

    /// 更新已有 key 不增容量、不触发淘汰。
    func testUpdateExistingKeyDoesNotEvict() {
        var store = LRUStore<String, Int>()
        store.set("a", 1, maxEntries: 2)
        store.set("b", 2, maxEntries: 2)
        store.set("a", 10, maxEntries: 2)  // 更新而非新增
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.get("a"), 10)
        XCTAssertEqual(store.get("b"), 2)
    }
}
