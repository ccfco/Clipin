# Clipin

现代化 macOS 剪贴板管理器。Rust 后端 + SwiftUI 前端。

## 架构

- **Rust Core**（`rust/`）：存储（SQLite+FTS5）、搜索、数据模型
- **Swift UI**（`Clipin/`）：SwiftUI 界面、系统集成（menu bar、快捷键、剪贴板监控）
- **UniFFI Bridge**：Rust ↔ Swift 互操作，自动生成绑定代码

## 构建

```bash
# 首次构建 Rust + 生成 Swift bindings
./scripts/build-rust.sh

# 生成 Xcode 项目
xcodegen generate

# 编译
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build

# Rust 测试
cd rust && cargo test --lib
```

## 关键路径

- `rust/src/lib.rs` — Rust 入口 + UniFFI 导出
- `Clipin/App/` — SwiftUI App 入口
- `Clipin/Generated/` — UniFFI 自动生成（.gitignore）
- `scripts/build-rust.sh` — 构建脚本
- `project.yml` — xcodegen 配置

## 决策

- **Bridging Header**（非 modulemap）：解决 Xcode Explicit Module Build 下 UniFFI C 头文件导入问题
- **xcodegen**：代码化管理 Xcode 项目，.xcodeproj 不提交
- **LSUIElement=true**：纯 menu bar app，不出现在 Dock
