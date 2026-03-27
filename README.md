<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Clipin">
</p>

<h1 align="center">Clipin</h1>

<p align="center">
  轻量、快速、键盘优先的 macOS 剪贴板管理器<br>
  <sub>A tiny, keyboard-first clipboard manager for macOS, built to stay fast and stay out of your way.</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-orange" alt="Rust 1.75+">
  <img src="https://img.shields.io/badge/Swift-6.0-red" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/version-0.1.2-brightgreen" alt="v0.1.2">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  <a href="#安装">下载</a> · <a href="#快捷键">快捷键</a> · <a href="#路线图">路线图</a> · <a href="#english">English</a>
</p>

<p align="center">
  小体积原生应用 · 本地优先 · 菜单栏常驻 · 为连续粘贴而设计
</p>

## 为什么是 Clipin

`Clipin` 不是一个把功能越堆越多的“剪贴板工具箱”，而是一个为高频复制/粘贴场景优化的原生 macOS 工具。它的目标很直接：打开快、搜索快、粘贴快，长期常驻时尽量少打扰你，也尽量少拖累系统。

- **包体积小，安装负担低** — 当前仓库本地 `Release` 构建的 `Clipin.app` 约 `6.6 MB`，压缩后约 `2.7 MB`。原生 `SwiftUI + Rust` 架构，没有 Electron 级运行时包袱。
- **搜索和切换很快** — `Rust + SQLite + FTS5 trigram` 做中英文全文检索，输入即查，适合把剪贴板当成可搜索的短期记忆。
- **为低负担常驻而设计** — 主列表只加载轻量摘要，右侧详情按需异步读取，避免把整段长文本和全部历史一次性塞进 UI。
- **对系统和注意力都更克制** — 菜单栏形态，不出现在 Dock；支持保留策略、数量上限和去重，减少历史膨胀与无效噪音。
- **真正键盘优先** — 打开、筛选、执行动作、连续粘贴都能靠键盘完成，用起来更像 launcher，而不是只能翻历史的面板。

## 功能亮点

🪶 **轻量原生** — 原生 `SwiftUI` 外壳 + `Rust` 核心，安装包和运行负担都更克制，适合长期常驻

🔍 **即时搜索** — 中英文全文检索（FTS5 trigram），输入即匹配，短查询自动回退 `LIKE`

⌨️ **键盘优先** — 方向键导航、回车粘贴、`⌘1-9` 快速粘贴前 9 条

📌 **连续粘贴** — ⌘⇧L 开启 Stay 模式，跨应用点击输入框后面板自动夺回焦点，连续选择并粘贴

🎯 **动作面板** — `⌘K` 打开命令面板，键入即筛选，空态下也始终可用

🧠 **低负担列表** — 列表只展示轻量摘要，完整内容按需加载，大文本历史也不容易拖慢面板

🔒 **隐私优先** — 数据全部本地 SQLite 存储，自动跳过密码管理器等敏感剪贴板内容

📁 **多文件感知** — Finder 多选复制完整保留，粘贴和 Reveal 都按整组处理

♾️ **长期存储** — 支持 7 天到永久保留，条目上限最高 50K 或不限

⚡ **为常驻优化** — 菜单栏应用，不出现在 Dock；默认流程克制，尽量把打扰感压到最低

## 安装

### 直接下载

1. 前往 [Releases](https://github.com/ccfco/Clipin/releases/latest) 下载最新 `Clipin-vX.X.X-macOS.zip`
2. 解压得到 `Clipin.app`，拖入 `/Applications`
3. 首次打开如果被系统拦截，右键点"打开"完成确认
4. 授予「辅助功能」权限后即可使用

### 源码构建

需要：Rust stable、Xcode 16+、[xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/ccfco/Clipin.git
cd Clipin

# 构建 Rust core + 生成 Swift bindings
./scripts/build-rust.sh

# 生成 Xcode 项目
xcodegen generate

# 构建并部署到 /Applications（含稳定签名，辅助功能权限不丢失）
./scripts/deploy.sh
```

## 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘⇧V` | 打开/关闭剪贴板面板 |
| `↑` `↓` | 上下导航 |
| `↵` | 粘贴选中项 |
| `⇧↵` | 以纯文本粘贴 |
| `⌘1`–`⌘9` | 快速粘贴前 9 条 |
| `⌘C` | 复制到剪贴板（不粘贴） |
| `⌘⇧P` | 固定/取消固定 |
| `⌘⌫` | 删除条目 |
| `⌘O` | 打开 URL / 在 Finder 中显示文件 |
| `⌘K` | 打开动作面板 |
| `Tab` / `⇧Tab` | 切换类型筛选 |
| `⌘⇧L` | 开启/关闭 Stay 模式 |
| `⌘,` | 打开设置 |
| `Esc` | 先清除搜索/筛选，再关闭面板 |

## 路线图

**计划中：**

- [ ] iCloud 同步
- [ ] 多主题支持
- [ ] 多语言（i18n）
- [ ] 浮动笔记模式

**已完成：**

- [x] 连续粘贴（Stay 模式）
- [x] 长期/永久历史保留
- [x] FTS5 全文搜索
- [x] 动作面板 + 键入筛选
- [x] 隐私感知采集

## 架构

```
┌─────────────────────────────────────────┐
│              SwiftUI Frontend            │
│  MainPanel · SearchBar · PreviewPane    │
├─────────────────────────────────────────┤
│           UniFFI Bridge (auto-gen)       │
├─────────────────────────────────────────┤
│              Rust Core                   │
│  SQLite + FTS5 · Search · Data Model    │
└─────────────────────────────────────────┘
```

- **Rust** — 存储、搜索、数据完整性，通过 SQLite + FTS5 实现
- **SwiftUI** — Raycast 风格双栏布局，原生 macOS 体验
- **UniFFI** — 自动生成 Swift ↔ Rust 绑定

## 项目结构

```
Clipin/
├── rust/src/          # Rust core（存储、模型、搜索）
├── Clipin/
│   ├── App/           # AppDelegate，入口
│   ├── Views/         # SwiftUI 视图
│   ├── ViewModels/    # ClipboardViewModel
│   ├── Services/      # 剪贴板监控、粘贴服务、热键
│   └── Generated/     # UniFFI 自动生成（gitignored）
├── scripts/
│   ├── build-rust.sh  # 构建 Rust + 生成绑定
│   └── deploy.sh      # 部署到 /Applications（含稳定签名）
└── project.yml        # xcodegen 配置
```

---

<details id="english">
<summary><strong>English</strong></summary>

## What is Clipin?

Clipin is a tiny, keyboard-first clipboard manager for macOS. It is built to launch fast, search fast, and stay quietly in your menu bar without feeling heavy.

**Why it stands out:**
- Small native footprint: current local Release build is about `6.6 MB` (`~2.7 MB` zipped)
- Fast search: `Rust + SQLite + FTS5 trigram` with Chinese and English full-text lookup
- Low-overhead UI: lightweight list items in the main panel, full details loaded on demand
- Keyboard-first flow: arrow keys, Enter to paste, `⌘1-9` quick paste, `⌘K` action palette
- Stay mode (`⌘⇧L`): continuous paste across apps without repeated hotkey presses
- Privacy-first: all data stays local, and sensitive clipboard content is automatically skipped

## Install

Download the latest `.zip` from [Releases](https://github.com/ccfco/Clipin/releases/latest), unzip, drag to `/Applications`, and grant Accessibility permission on first launch.

Or build from source:

```bash
git clone https://github.com/ccfco/Clipin.git && cd Clipin
./scripts/build-rust.sh && xcodegen generate && ./scripts/deploy.sh
```

</details>

## License

MIT
