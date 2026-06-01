import Foundation

/// 简易 LRU 缓存原语：dict O(1) 查询 + 顺序数组 O(n) 触达。容量上限 ≤ 数百，
/// touch 的 removeAll/append 成本可忽略。
///
/// **本身不做任何隔离**：是个 `struct`，由持有者（actor / @MainActor / NSLock 域）负责串行化访问。
/// 这正是它能被不同隔离模型的缓存（FaviconCache=actor、WebScreenshotCache=@MainActor、
/// PreviewMetadataCache=NSLock）共享的原因——淘汰逻辑与隔离机制解耦。
///
/// 收敛了此前 5 处各写一遍的 `cache + lru + store + touch` 三件套。pending dedup / 磁盘回填等
/// 是各缓存自身职责，不属于本原语——本原语只管「内存条目的容量淘汰」这一件事。
struct LRUStore<Key: Hashable, Value> {
    private var map: [Key: Value] = [:]
    private var order: [Key] = []

    var count: Int { map.count }

    /// 读并触达：命中则把 key 移到最近端。未命中返回 nil。
    mutating func get(_ key: Key) -> Value? {
        guard let value = map[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return value
    }

    /// 写入并维护上限：插入**新** key 且已达上限时，先淘汰最久未访问者再插入；更新已有 key 不淘汰。
    mutating func set(_ key: Key, _ value: Value, maxEntries: Int) {
        if map[key] == nil, map.count >= maxEntries, let lru = order.first {
            map.removeValue(forKey: lru)
            order.removeFirst()
        }
        map[key] = value
        order.removeAll { $0 == key }
        order.append(key)
    }
}
