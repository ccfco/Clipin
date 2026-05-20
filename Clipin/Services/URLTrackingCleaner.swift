import Foundation

/// 基于 ClearURLs Rules 数据的 URL tracking 参数清理引擎。
///
/// **为什么自己写引擎 + 用别人的数据**：
/// - ClearURLs 社区维护了 200+ 站点的精细规则（rules / rawRules / exceptions / redirections），
///   这是任何手列方案都做不到的覆盖度
/// - Swift 生态没有 ClearURLs 端口，引一个第三方库会破坏项目"零 Swift 依赖"的洁癖
/// - 算法本身（按 host 匹配 provider → 应用 rules → 解 redirections）只需要 ~200 行
///
/// **规则数据来源**：Clipin/Resources/clearurls-rules.json（编译期嵌入 bundle），
/// 通过 `scripts/update-clearurls.sh` 定期从 upstream 拉取快照 commit 进仓库。
/// 不在运行时下载，避免：① 沙盒/离线场景失败 ② upstream 改 schema 后线上突然炸 ③
/// 给上游加流量负担。
///
/// **与 ClearURLs 浏览器扩展的语义差异**：
/// - `completeProvider: true` 在浏览器里表示"整段 URL 阻止访问"。剪贴板场景没有"阻止"
///   语义，遇到这类 URL 直接跳过清理（不修改）。
/// - `referralMarketing` 在浏览器里给用户开关（保留 = 朋友点击给你积赞）。剪贴板用户
///   外发链接给同事的语义是"干净分享"，默认删除。
/// - `forceRedirection` 在浏览器里表示"redirection 失败时硬阻止"。剪贴板场景下
///   redirection 失败就保留原 URL，不阻止。
final class URLTrackingCleaner: @unchecked Sendable {
    static let shared = URLTrackingCleaner()

    /// 单次清理结果。
    /// `didModify` 是核心调用判断：原 URL 与 cleaned URL 完全相同 → 无需展示 "Clean copy" 按钮。
    struct CleanResult: Equatable {
        let original: String
        let cleaned: String
        let removedParams: [String]
        let redirected: Bool

        var didModify: Bool { original != cleaned }
    }

    private struct CompiledProvider {
        let name: String
        let urlPattern: NSRegularExpression
        let completeProvider: Bool
        let rules: [NSRegularExpression]
        let rawRules: [NSRegularExpression]
        let referralMarketing: [NSRegularExpression]
        let exceptions: [NSRegularExpression]
        let redirections: [NSRegularExpression]
    }

    private let providers: [CompiledProvider]

    /// 最大重定向解嵌套层数：广告平台经常嵌套多层（adservice.google.com → t.co → 真实目标）。
    /// 5 层足够覆盖 99% 现实场景；防御性上限避免坏规则形成死循环。
    private let maxRedirectDepth = 5

    init() {
        self.providers = Self.loadProviders()
    }

    // MARK: - Public API

    /// 清理 URL 中的 tracking 参数 / 解嵌套重定向包装。
    ///
    /// 算法分两阶段：
    /// 1. **解 redirection 包装**（最多 maxRedirectDepth 层）：识别 `google.com/url?q=<real>`、
    ///    `t.co/<short>` 等转跳包装，提取目标 URL 后继续递归（目标本身可能仍带 tracking）
    /// 2. **删 tracking 参数**：在最终 URL 上应用所有匹配 provider 的 rules / referralMarketing
    ///    （query 参数名）+ rawRules（整条 URL 的 regex 替换）
    ///
    /// 输入不是有效 URL 或无任何变化时，返回 didModify=false 的结果。
    func clean(_ urlString: String) -> CleanResult {
        var current = urlString
        var allRemoved: [String] = []
        var didRedirect = false

        // 阶段 1：解嵌套 redirection
        for _ in 0..<maxRedirectDepth {
            guard let next = applyRedirection(to: current), next != current else { break }
            current = next
            didRedirect = true
        }

        // 阶段 2：删 tracking 参数 + rawRules
        let (afterClean, removed) = applyParameterAndRawRules(to: current)
        current = afterClean
        allRemoved.append(contentsOf: removed)

        return CleanResult(
            original: urlString,
            cleaned: current,
            removedParams: allRemoved,
            redirected: didRedirect
        )
    }

    // MARK: - Phase 1: Redirection unwrapping

    /// 在 URL 上尝试一次 redirection 解嵌套。
    /// 找到匹配的 redirection 规则后提取嵌套 URL 并 percent-decode 返回；否则返回 nil。
    private func applyRedirection(to urlString: String) -> String? {
        let nsURL = urlString as NSString
        let fullRange = NSRange(location: 0, length: nsURL.length)

        for provider in providers {
            // urlPattern 不匹配 → 不是这个 provider 的责任
            guard provider.urlPattern.firstMatch(in: urlString, range: fullRange) != nil else { continue }
            // exception 命中 → 跳过该 provider 的所有处理（特殊路径必须保留原 URL）
            if provider.exceptions.contains(where: { $0.firstMatch(in: urlString, range: fullRange) != nil }) {
                continue
            }
            // completeProvider：剪贴板场景下不动 URL
            if provider.completeProvider { continue }

            for redir in provider.redirections {
                guard let match = redir.firstMatch(in: urlString, range: fullRange),
                      match.numberOfRanges >= 2,
                      let captureRange = Range(match.range(at: 1), in: urlString) else { continue }
                let extracted = String(urlString[captureRange])
                // 嵌套 URL 通常 percent-encoded（"https%3A%2F%2F..."），decode 一次
                let decoded = extracted.removingPercentEncoding ?? extracted
                // 校验解出来的确实是个 URL（http/https），否则可能是规则误匹配
                guard decoded.hasPrefix("http://") || decoded.hasPrefix("https://") else { continue }
                return decoded
            }
        }
        return nil
    }

    // MARK: - Phase 2: Parameter & rawRules removal

    /// 在 URL 上应用所有匹配 provider 的 rules / referralMarketing / rawRules，
    /// 返回 (cleaned URL, 被删的参数名列表)。
    ///
    /// **rules + referralMarketing 合并处理**：两者语义都是"query 参数名匹配即删"，
    /// 在剪贴板场景下都应删。把 rawRules 放最后，因为它直接 regex 替换 URL 整体，
    /// 在已经清干净 query 的 URL 上更精确。
    private func applyParameterAndRawRules(to urlString: String) -> (String, [String]) {
        var current = urlString
        var allRemoved: [String] = []

        for provider in providers {
            // **每次循环都必须重新算 fullRange**：上一轮 provider 删参后 current 已变短，
            // 复用初始 fullRange 会让 NSRegularExpression 在更短的 string 上跑出超界 range，
            // 触发 NSException 或静默错乱。
            let nsCurrent = current as NSString
            let fullRange = NSRange(location: 0, length: nsCurrent.length)

            guard provider.urlPattern.firstMatch(in: current, range: fullRange) != nil else { continue }
            if provider.exceptions.contains(where: { $0.firstMatch(in: current, range: fullRange) != nil }) {
                continue
            }
            if provider.completeProvider { continue }

            // 删 query 参数
            let allParamPatterns = provider.rules + provider.referralMarketing
            let (afterParamClean, removed) = removeQueryParams(in: current, matching: allParamPatterns)
            current = afterParamClean
            allRemoved.append(contentsOf: removed)

            // 应用 rawRules（regex 替换整条 URL）。同样每次取最新 range。
            for rawRule in provider.rawRules {
                let r = NSRange(location: 0, length: (current as NSString).length)
                let replaced = rawRule.stringByReplacingMatches(in: current, range: r, withTemplate: "")
                // 替换后 URL 仍合法才接受（rawRule 偶有把整条 URL 替光的情况）
                if URL(string: replaced) != nil, !replaced.isEmpty {
                    current = replaced
                }
            }
        }
        return (current, allRemoved)
    }

    /// 删除 query 参数名匹配任一 pattern 的 query items。
    ///
    /// **匹配语义是"整段匹配"**：ClearURLs regex 写的是参数名整体，必须用 `match.range == fullRange`
    /// 校验防止 `utm_source` 被 `utm` 这种短 pattern 错删整个参数。
    ///
    /// **必须用 `percentEncodedQueryItems` 而非 `queryItems`**：剪贴板场景要字节保真。
    /// URLComponents.queryItems 是"语义层"API，会自动 decode value（`%2F` → `/`）再
    /// 重新 encode，最终输出可能跟原 URL 不一致——用户复制 Amazon 那种带 `%2F` value 的
    /// URL 会被悄悄改写。percentEncodedQueryItems 操作原始编码字节，name 比较时 decode
    /// 一次（pattern 是 ASCII，decode 也是 ASCII），写回时不改 value 编码。
    private func removeQueryParams(
        in urlString: String,
        matching patterns: [NSRegularExpression]
    ) -> (String, [String]) {
        guard !patterns.isEmpty,
              let url = URL(string: urlString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else {
            return (urlString, [])
        }
        var removed: [String] = []
        let kept = items.filter { item in
            // name 在 ClearURLs 规则里都是 ASCII，但严谨起见 decode 后再匹配
            // （万一某个站点用了非 ASCII param name，decoded name 匹配规则的语义更稳）
            let decodedName = item.name.removingPercentEncoding ?? item.name
            let nsName = decodedName as NSString
            let range = NSRange(location: 0, length: nsName.length)
            for pattern in patterns {
                if let match = pattern.firstMatch(in: decodedName, range: range),
                   match.range == range {
                    removed.append(decodedName)
                    return false
                }
            }
            return true
        }
        guard removed.count > 0 else { return (urlString, []) }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return (components.url?.absoluteString ?? urlString, removed)
    }

    // MARK: - Loading

    /// 从 bundle 加载 ClearURLs JSON 并预编译所有 regex。
    ///
    /// **编译失败的规则跳过**：ClearURLs regex 用 PCRE 语法，NSRegularExpression 不完全
    /// 兼容（如 lookbehind 受限）。一条坏规则不能拖垮整个引擎——`try?` + `compactMap`
    /// 让坏规则静默丢弃，引擎仍提供其他 200+ provider 的规则。
    ///
    /// JSON 加载失败（资源缺失/格式错）→ 返回空数组，cleaner.clean() 退化为"恒等函数"，
    /// 不影响其他功能。
    private static func loadProviders() -> [CompiledProvider] {
        guard let url = Bundle.main.url(forResource: "clearurls-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerDict = json["providers"] as? [String: Any] else {
            return []
        }

        var compiled: [CompiledProvider] = []
        for (name, value) in providerDict {
            guard let p = value as? [String: Any],
                  let urlPatternStr = p["urlPattern"] as? String,
                  let urlPattern = try? NSRegularExpression(
                    pattern: urlPatternStr,
                    options: .caseInsensitive
                  ) else {
                continue
            }
            compiled.append(CompiledProvider(
                name: name,
                urlPattern: urlPattern,
                completeProvider: p["completeProvider"] as? Bool ?? false,
                rules: compilePatterns(p["rules"] as? [String] ?? []),
                rawRules: compilePatterns(p["rawRules"] as? [String] ?? []),
                referralMarketing: compilePatterns(p["referralMarketing"] as? [String] ?? []),
                exceptions: compilePatterns(p["exceptions"] as? [String] ?? []),
                redirections: compilePatterns(p["redirections"] as? [String] ?? [])
            ))
        }
        return compiled
    }

    private static func compilePatterns(_ patterns: [String]) -> [NSRegularExpression] {
        patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }
}
