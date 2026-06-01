import Foundation

extension String {
    /// FNV-1a 64-bit 稳定哈希。
    ///
    /// 为什么不用标准库 `Hasher`：`Hasher` 每次进程启动用随机种子，**同一字符串跨启动哈希值不同**。
    /// 凡是需要「跨启动一致」的派生值——磁盘缓存文件名、host→稳定背景色——都不能用 `Hasher`，
    /// 必须用确定性算法。FNV-1a 实现极简、分布够散、无第三方依赖，正合此用。
    ///
    /// 调用方各自后处理：磁盘文件名取 `String(format: "%016llx", _)`，颜色取 `_ % 360` 当 hue。
    func fnv1aHash() -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}
