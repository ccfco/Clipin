# Clipin 更新提醒方案设计

## 目标

在 **不依赖签名 / 不做自动安装** 的前提下，为 Clipin 提供一套可靠、低打扰的更新提醒能力：

- 能发现 GitHub 上有新 release
- 能在 app 内告诉用户“更新了什么”
- 能一键跳到 release 页面或直接下载 zip
- 适配 Clipin 的 menu bar / launcher 心智，不做抢焦点弹窗

## 明确不做

- 不做自动下载后覆盖安装
- 不做 Sparkle / appcast
- 不做需要 Apple Developer 账号的签名、公证链路
- 不做复杂渠道管理（stable / beta）

## 为什么现在不用 Sparkle

当前 Clipin 是免费、无正式签名分发。

这种状态下最稳的方案不是“自动更新”，而是：

1. GitHub Releases 作为唯一发布源
2. App 内做更新检查和更新说明展示
3. 用户手动跳转下载

这样实现成本低，也不会给用户制造“支持自动更新”的错误预期。

## 数据源

直接使用 GitHub Releases API：

- `GET https://api.github.com/repos/ccfco/Clipin/releases/latest`

当前接口已经能拿到本方案所需字段：

- `tag_name`
- `html_url`
- `published_at`
- `body`
- `assets[].name`
- `assets[].browser_download_url`

## 核心交互

### 1. 自动检查

- app 启动后延迟几秒做一次后台检查
- 之后每 `12h` 或 `24h` 最多检查一次
- 默认开启“自动检查更新”
- 如果用户手动点击“检查更新”，则忽略节流

### 2. 菜单栏提醒

菜单栏右键菜单新增：

- `Check for Updates...`
- 如果发现新版本，则在顶部显示：
  - `New Version Available: v0.1.6`
- 点击后打开一个更新详情面板，或者直接打开设置页里的 Updates 区块

不建议直接用系统通知作为主提醒方式，因为 menu bar app 的更新提醒更适合留在应用自身语境里。

### 3. 设置页入口

在 `Settings -> General` 下增加 `Updates` 分组：

- 当前版本：`v0.1.5`
- 自动检查更新：开关
- 上次检查时间
- 当前状态：
  - 已是最新
  - 发现新版本 `vX.Y.Z`
  - 检查失败
- `Check Now`
- `View Release`
- `Download Latest`

### 4. 更新说明展示

发现新版本后，展示 release body 的摘要。

建议：

- 先直接显示 GitHub release body 的纯文本版
- 保留原始 markdown，但 UI 层先渲染成简洁文本
- 最长只展示前 `N` 行或前 `1200-1600` 字，防止 release notes 过长把设置页撑坏
- 底部保留 `View Full Release` 跳转按钮

## 下载策略

不要硬编码 zip 文件名。

因为当前 release asset 名称并不完全稳定，所以下载链接应动态选择：

1. 优先找 `.zip`
2. 如果以后有 `.dmg`，可以优先 `.dmg`
3. 如果没有明确安装包资产，则退回 `html_url`

推荐封装一个选择逻辑：

- `preferredDownloadURL(from assets: [ReleaseAsset]) -> URL?`

规则：

1. 优先 `.dmg`
2. 其次 `.zip`
3. 否则 `nil`

## 本地状态设计

新增一组轻量设置。当前实现直接由 `UpdateReminderService` 读写 `UserDefaults`，后续如果更新相关状态继续膨胀，再考虑并回 `SettingsStore`：

- `updates.autoCheckEnabled: Bool`
- `updates.lastCheckedAt: Date?`
- `updates.dismissedVersion: String?`

### dismissedVersion 的作用

如果用户看到 `v0.1.6` 但暂时不想更新，可以点“稍后再说”。

此时：

- 不再反复高亮提醒 `v0.1.6`
- 但用户手动检查时仍可看到
- 一旦出现 `v0.1.7`，重新提醒

## 版本比较

本地版本取：

- `CFBundleShortVersionString`

远端版本取：

- `tag_name`

比较规则：

- 去掉前缀 `v`
- 仅按语义化数字段比较
- 例如：`0.1.10 > 0.1.9`

## 建议的实现拆分

### `ReleaseChecker`

负责：

- 请求 GitHub latest release API
- 解析 JSON
- 比较版本
- 选择下载链接

输出模型建议：

```swift
struct ReleaseInfo {
    let version: String
    let publishedAt: Date?
    let notes: String
    let releasePageURL: URL
    let downloadURL: URL?
}
```

### `UpdateReminderStore`

负责：

- 自动检查开关
- 上次检查时间
- 已忽略版本

### `UpdateReminderService`

负责：

- 启动时触发检查
- 给菜单栏和设置页提供状态
- 响应“Check Now / View Release / Download”

## 与当前代码的接入点

最适合接入的位置：

- 菜单栏右键菜单：`Clipin/App/AppDelegate.swift`
- 设置页 General：`Clipin/Views/SettingsView.swift`
- 用户设置持久化：`Clipin/Services/SettingsStore.swift`

## UI 细节建议

### 默认状态

- `You're up to date`
- 辅助文案显示上次检查时间

### 发现新版本

- 标题：`Clipin v0.1.6 is available`
- 摘要：显示发布时间和更新说明前几段
- 按钮：
  - `Download Latest`
  - `View Release`
  - `Later`

### 检查失败

- 文案只说：
  - `Couldn't check for updates right now.`
- 不要把 GitHub API 原始错误直接暴露给普通用户
- 调试日志可以保留更详细错误

## 节流与容错

- 自动检查节流：`12h` 或 `24h`
- 手动检查不节流
- 请求超时建议 `8-10s`
- GitHub API 失败时静默降级，不影响 app 主流程
- 没网、接口限流、release body 为空都不应影响主界面

## 产品层面的取舍

### 为什么不做启动即弹窗

Clipin 是 menu bar 工具，不应像大型桌面应用那样一启动就打断用户。

更符合产品心智的方式是：

- 菜单项高亮
- 设置页可见
- 用户主动查看详情

### 为什么要显示 release notes

“有更新”本身价值不高，用户真正关心的是：

- 这次更新有没有我想要的东西
- 值不值得我现在下载

所以“版本号 + 发布时间 + 更新说明摘要 + 下载按钮”是最小完整闭环。

## 分阶段落地

### Phase 1

- 加 `ReleaseChecker`
- 菜单栏 `Check for Updates...`
- 设置页 `Updates` 分组
- 展示 release notes 摘要
- 跳转 GitHub Release / 下载 zip

当前代码已经落地到这一阶段，命名上收口为单一 `UpdateReminderService`，避免一开始就拆成多层 coordinator / store。

### Phase 2

- 支持 `dismissedVersion`
- 设置页显示“上次检查时间”
- 菜单栏有轻提示

### Phase 3

- 若未来开始正式签名分发，再评估是否切换 Sparkle
- 保留现有 UI，不改用户心智，只替换底层实现

## 结论

对当前 Clipin，最合适的不是“自动更新”，而是：

**GitHub Releases 驱动的应用内更新提醒 + 更新说明展示 + 手动下载跳转。**

这条路实现最轻、风险最低，也最符合你当前的免费分发状态。
