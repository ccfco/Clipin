import AppKit
import Foundation

struct LocalPathResolution: Equatable, Sendable {
    let url: URL
    let isDirectory: Bool
}

struct InlinePathCandidate: Equatable, Sendable {
    let range: NSRange
    let rawPath: String
}

enum LocalPathDetector {
    private static let maxSinglePathLength = 4096
    private static let maxInlineScanUTF16Length = 50_000
    private static let defaultMaxInlineCandidates = 30
    private static let trailingTrimCharacters = CharacterSet(charactersIn: ".,;:!?")

    /// 匹配被引号包裹的路径（可含空格），例如 `"/Users/foo/My Folder"` 或 `'~/My Docs'`。
    private static let quotedPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_:])(["'])(~(?:/[^"'\r\n]+)?|/(?!/)(?:[^"'\r\n]*))\1"#
    )

    /// 匹配裸露的绝对路径或 `~/` 路径，要求前置边界（行首、空白或常见分隔符），
    /// 避免把普通文本里的 `a/b` 或 URL 片段误认成本地路径。
    private static let unquotedPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?:^|[\s(\[\{`"'=:,;])((?:~(?:/[^\s"'`<>()\[\]{}]*)?|/(?!/)(?:[^\s"'`<>()\[\]{}]+)))"#
    )

    /// 纯字符串启发式：单行、非空、看起来像绝对路径或 `~/` 路径（不触发任何磁盘 IO）。
    static func looksLikeSingleLocalPath(_ raw: String) -> Bool {
        normalizedCandidateString(from: raw) != nil
    }

    /// 仅做字符串规范化与 `~` 展开，不触发磁盘 IO。
    static func expandedPath(from raw: String) -> String? {
        guard let candidate = normalizedCandidateString(from: raw) else { return nil }
        return (candidate as NSString).expandingTildeInPath
    }

    /// 判断 `URL` 是否为真正的"可进目录"文件夹（排除 `.app` / `.xcodeproj` / `.rtfd` 等包）。
    /// 对包调用 `NSWorkspace.shared.open` 会启动应用或打开文档，而不是打开访达。
    static func isTrueDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// 检查单条字符串是否指向本机真实存在的文件或文件夹。
    /// 可能触发文件系统 stat，只应在后台任务或用户显式动作中调用。
    static func resolveSinglePath(
        from raw: String,
        fileManager: FileManager = .default
    ) -> LocalPathResolution? {
        guard let expanded = expandedPath(from: raw) else { return nil }
        var isDirObjC: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirObjC) else {
            return nil
        }
        let probeURL = URL(fileURLWithPath: expanded, isDirectory: isDirObjC.boolValue)
        let openAsDirectory = isDirObjC.boolValue && isTrueDirectory(probeURL)
        return LocalPathResolution(
            url: URL(fileURLWithPath: expanded, isDirectory: openAsDirectory),
            isDirectory: openAsDirectory
        )
    }

    /// 从任意文本中提取非 URL 区间的本地路径候选（纯文本扫描，不触发磁盘 IO）。
    static func extractInlineCandidates(
        in text: String,
        excluding excludedRanges: [NSRange],
        maxCandidates: Int = defaultMaxInlineCandidates
    ) -> [InlinePathCandidate] {
        let nsText = text as NSString
        guard nsText.length > 0, nsText.length <= maxInlineScanUTF16Length, maxCandidates > 0 else {
            return []
        }

        let fullRange = NSRange(location: 0, length: nsText.length)
        var claimedRanges = excludedRanges
        var candidates: [InlinePathCandidate] = []

        func overlapsClaimed(_ range: NSRange) -> Bool {
            claimedRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        // 0) 整行就是一个本地路径（支持 Finder ⌘⌥C 复制的不带引号含空格路径、多文件 Path 列表）
        var lineCursor = 0
        while lineCursor < nsText.length, candidates.count < maxCandidates {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineCursor, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if lineRange.length > 0,
               let wholeLineRange = wholeLinePathRange(in: nsText, lineRange: lineRange),
               !overlapsClaimed(wholeLineRange) {
                let rawPath = nsText.substring(with: wholeLineRange)
                candidates.append(InlinePathCandidate(range: wholeLineRange, rawPath: rawPath))
                claimedRanges.append(lineRange)
            }
            lineCursor = max(lineEnd, lineCursor + 1)
        }

        if candidates.count >= maxCandidates {
            return candidates.sorted { $0.range.location < $1.range.location }
        }

        // 1) 引号包裹路径优先（支持带空格的路径）
        quotedPathRegex?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
            guard let match, match.numberOfRanges >= 3 else { return }
            let pathRange = match.range(at: 2)
            guard pathRange.location != NSNotFound, pathRange.length > 0 else { return }
            guard !overlapsClaimed(pathRange) else { return }

            let rawPath = nsText.substring(with: pathRange)
            guard rawPath.count <= maxSinglePathLength else { return }
            candidates.append(InlinePathCandidate(range: pathRange, rawPath: rawPath))
            claimedRanges.append(pathRange)
            if candidates.count >= maxCandidates {
                stop.pointee = true
            }
        }

        if candidates.count >= maxCandidates {
            return candidates
        }

        // 2) 未加引号的路径（跳过 URL 与已提取的引号路径）
        unquotedPathRegex?.enumerateMatches(in: text, options: [], range: fullRange) { match, _, stop in
            guard let match, match.numberOfRanges >= 2 else { return }
            var pathRange = match.range(at: 1)
            guard pathRange.location != NSNotFound, pathRange.length > 0 else { return }

            var rawPath = nsText.substring(with: pathRange)
            while let lastScalar = rawPath.unicodeScalars.last,
                  rawPath.count > 1,
                  trailingTrimCharacters.contains(lastScalar) {
                let lastUTF16Count = String(lastScalar).utf16.count
                rawPath.unicodeScalars.removeLast()
                pathRange.length -= lastUTF16Count
            }

            guard pathRange.length > 0,
                  rawPath.count <= maxSinglePathLength,
                  rawPath != "/",
                  !overlapsClaimed(pathRange) else {
                return
            }

            candidates.append(InlinePathCandidate(range: pathRange, rawPath: rawPath))
            claimedRanges.append(pathRange)
            if candidates.count >= maxCandidates {
                stop.pointee = true
            }
        }

        return candidates.sorted { $0.range.location < $1.range.location }
    }

    // MARK: - Private

    /// 若整行（去掉首尾空白及成对外层引号后）符合单个本地路径语法，则返回其精确 UTF-16 `NSRange`。
    private static func wholeLinePathRange(in nsText: NSString, lineRange: NSRange) -> NSRange? {
        guard lineRange.length > 0 else { return nil }
        let lineString = nsText.substring(with: lineRange)
        guard looksLikeSingleLocalPath(lineString) else { return nil }

        var start = lineRange.location
        var end = NSMaxRange(lineRange)

        while start < end,
              let scalar = UnicodeScalar(nsText.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }
        while end > start,
              let scalar = UnicodeScalar(nsText.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }

        if end - start >= 2 {
            let first = nsText.character(at: start)
            let last = nsText.character(at: end - 1)
            let quoteChars: [unichar] = [0x22, 0x27] // " and '
            if first == last, quoteChars.contains(first) {
                start += 1
                end -= 1
                while start < end,
                      let scalar = UnicodeScalar(nsText.character(at: start)),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    start += 1
                }
                while end > start,
                      let scalar = UnicodeScalar(nsText.character(at: end - 1)),
                      CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    end -= 1
                }
            }
        }

        let length = end - start
        guard length > 0, length <= maxSinglePathLength else { return nil }
        return NSRange(location: start, length: length)
    }

    private static func normalizedCandidateString(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maxSinglePathLength,
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else {
            return nil
        }

        let unquoted: String
        if trimmed.count >= 2,
           ((trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'"))) {
            unquoted = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unquoted = trimmed
        }

        guard !unquoted.isEmpty else { return nil }
        let isTildePath = unquoted == "~" || unquoted.hasPrefix("~/")
        let isAbsolutePath = unquoted.hasPrefix("/") && !unquoted.hasPrefix("//") && unquoted != "/"
        guard isTildePath || isAbsolutePath else { return nil }
        return unquoted
    }
}
