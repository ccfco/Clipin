import Foundation
import os

/// 全局统一日志入口。
///
/// 为什么不用 `print`：Clipin 是 `LSUIElement` 菜单栏 app——没有终端窗口承载 stderr，
/// 用户/我们要事后排查问题只剩 Console.app 这一条路。`print` 写出去的字符串落到
/// stderr 后就只能靠 `Console.app -> 设备日志` 翻历史，过滤维度只剩进程名；用
/// `os.Logger` 则可以按 subsystem/category 一键过滤，并且日志条目带级别、时间戳、
/// 文件:行号元数据。终端命令行也能直接拉：
///
/// ```sh
/// log show --predicate 'subsystem == "com.ccfco.Clipin"' --last 1h --info --debug
/// ```
///
/// Apple 文档：https://developer.apple.com/documentation/os/logger
///
/// **隐私脱敏（重要）**：`os.Logger` 默认会把字符串插值变量在 release 构建里打成
/// `<private>`，要让具体值在 Console.app 可见必须显式 `\(value, privacy: .public)`。
/// Clipin 的诊断日志里 id / 路径 / 错误类型都属于「故障排查必须可见、且非用户机密」
/// 的字段，按需标 public；剪贴板真实内容、文件名等才是隐私字段，仍保持默认 private。
enum ClipinLog {
    /// 与 bundle id 对齐，方便 Console.app 直接按 subsystem 列出所有 Clipin 日志。
    private static let subsystem = "com.ccfco.Clipin"

    /// 应用生命周期、面板、键盘路由等顶层 AppDelegate 行为。
    static let app = Logger(subsystem: subsystem, category: "app")

    /// ClipboardViewModel：列表加载、选中、搜索、编辑等 UI 状态层。
    static let viewModel = Logger(subsystem: subsystem, category: "viewmodel")

    /// 粘贴主流程（写剪贴板、读 representations、incrementPasteCount）。
    static let paste = Logger(subsystem: subsystem, category: "paste")

    /// 历史清理（自动清理 + 设置页手动清理）。
    static let cleanup = Logger(subsystem: subsystem, category: "cleanup")

    /// 图片 OCR 文本识别（Vision Framework）+ 历史回填。
    static let ocr = Logger(subsystem: subsystem, category: "ocr")

    /// 图片尺寸读取与历史回填。
    static let imageDimensions = Logger(subsystem: subsystem, category: "imageDimensions")

    /// ClipinCore（Rust 层）初始化与启动信息。
    static let core = Logger(subsystem: subsystem, category: "core")

    /// 剪贴板轮询监控（ClipboardMonitor 写库、去重、OCR 串联）。
    static let monitor = Logger(subsystem: subsystem, category: "monitor")

    /// 全局快捷键注册与回调（HotKeyService）。
    static let hotKey = Logger(subsystem: subsystem, category: "hotkey")

    /// 更新检查（UpdateReminderService GitHub releases 拉取）。
    static let update = Logger(subsystem: subsystem, category: "update")

    /// SettingsStore：偏好读写与启动期 onboarding 判定。
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
