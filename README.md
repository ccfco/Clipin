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
  <img src="https://img.shields.io/badge/version-0.1.6-brightgreen" alt="v0.1.6">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

<p align="center">
  <img src="docs/preview.png" width="800" alt="Clipin Preview">
</p>

<p align="center">
  <a href="#安装">下载</a> · <a href="#快捷键">快捷键</a> · <a href="#路线图">路线图</a> · <a href="#english">English</a>
</p>

<p align="center">
  图片 OCR 搜索 · 系统级玻璃质感 · 位置记忆 · 连续粘贴
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

🖼️ **图片 OCR** — 基于 Apple Vision Framework 实现本地图片文字识别，支持中英文搜索图片内容

👀 **空格快速预览** — `Space` 调起系统 Quick Look 预览图片、文件与链接，支持在预览中继续用方向键切换下一条

🎨 **Liquid Glass 主题** — 适配 macOS 26 风格设计，提供 Native/Mist/Graphite/Sunrise 四种精选主题

🔍 **即时搜索** — 中英文全文检索（FTS5 trigram），输入即匹配，短查询自动回退 `LIKE`

⌨️ **键盘优先** — 方向键导航、回车粘贴、`⌘1-9` 快速粘贴前 9 条

📌 **连续粘贴** — `⌘⇧L` 开启连续粘贴模式，跨应用点击输入框后面板自动夺回焦点，连续选择并粘贴

📍 **位置记忆** — 面板自动记住上次在屏幕上的位置，支持跨重启持久化留存

🎯 **动作面板** — `⌘K` 打开静态命令面板，空态下也始终可用

🔒 **隐私优先** — 数据全部本地 SQLite 存储，自动跳过密码管理器等敏感内容

☁️ **自动备份** — 可备份到 iCloud Drive 或任意文件夹，支持多种同步频率

🔔 **更新提醒** — 内建 GitHub Releases 检查，可直接查看更新说明并跳转下载最新版

## 安装

### 直接下载

1. 前往 [Releases](https://github.com/ccfco/Clipin/releases/latest) 下载最新 `Clipin-vX.X.X-macOS.zip`
2. 解压得到 `Clipin.app`，拖入 `/Applications`
3. 首次打开如果被系统拦截，右键点"打开"完成确认
4. 首次启动会进入简短欢迎引导，记住主快捷键 `⌘⇧V`
5. 授予「辅助功能」权限后即可使用自动粘贴；未授权时也仍可浏览和再次复制历史

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
| `Space` | Quick Look 预览图片 / 文件 / 链接 |
| Quick Look 中 `↑` `↓` `←` `→` | 切换上一条 / 下一条可预览项 |
| `⌘K` | 打开动作面板 |
| `Tab` / `⇧Tab` | 切换类型筛选 |
| `⌘⇧L` | 开启/关闭连续粘贴 |
| `⌘,` | 打开设置 |
| `Esc` | 先清除搜索/筛选，再关闭面板 |

## 路线图

**计划中：**

- [ ] 拼音/首字母模糊搜索
- [ ] 浮动便签/参考面板模式
- [ ] iCloud 云同步

**已完成：**

- [x] 图片 OCR 文字识别与搜索
- [x] Native Liquid Glass 主题系统
- [x] 面板位置记忆 (持久化)
- [x] 连续粘贴模式 (Continuous Paste)
- [x] 空格键快速预览 (Quick Look)
- [x] 自动备份到 iCloud Drive / 本地文件夹
- [x] FTS5 全文搜索与动作面板
- [x] 隐私感知采集与多语言支持

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
- Image OCR search: built-in text recognition for images (zh/en support)
- Native Liquid Glass theme: modern macOS 26 style with 4 curated themes
- Instant search: fast FTS5-based search for text and image content
- Keyboard-first flow: arrow keys, Enter to paste, `⌘1-9` quick paste, `⌘K` palette
- Position memory: panel automatically remembers its last position on screen
- Continuous Paste mode (`⌘⇧L`): paste multiple items across apps seamlessly
- Privacy-first: all data stays local, automatically skips password managers

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
