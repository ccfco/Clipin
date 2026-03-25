<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Clipin">
</p>

<h1 align="center">Clipin</h1>

<p align="center">
  A modern clipboard manager for macOS.<br>
  Built with Rust + SwiftUI for speed and reliability.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.0%2B-blue" alt="macOS 15.0+">
  <img src="https://img.shields.io/badge/Rust-1.75%2B-orange" alt="Rust 1.75+">
  <img src="https://img.shields.io/badge/Swift-6.0-red" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

## Features

- **Instant search** — Filter clipboard history by keyword with highlight, supports Chinese and English
- **Keyboard-first** — Navigate with arrow keys, paste with Enter, ⌘1-9 for quick access
- **Smart dedup** — Repeated copies are merged, tracking copy count and timestamps
- **Rich preview** — Right pane shows full content, metadata, image thumbnails, and search highlights
- **Pin important items** — Pinned entries stay at the top, never expire
- **Type filtering** — Filter by Text, Image, File, or URL
- **Plain text paste** — ⇧Enter strips formatting
- **Copy without paste** — ⌘C puts item back on clipboard without pasting
- **Context menu** — Right-click items for Paste, Pin/Unpin, Delete
- **Smooth animations** — Fade in/out panel transitions
- **Long-term storage** — Keep clipboard history for 1–5 years with configurable retention
- **Privacy-first** — All data stored locally in SQLite, nothing leaves your machine

## Screenshot

> TODO: Add screenshot

## Installation

### Build from Source

Requires: Rust 1.75+, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
# Clone
git clone https://github.com/user/Clipin.git
cd Clipin

# Build Rust core + generate Swift bindings
./scripts/build-rust.sh

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build

# Deploy to /Applications (with stable code signing)
./scripts/deploy.sh
```

### First Launch

1. Open Clipin from `/Applications`
2. Grant **Accessibility** permission when prompted (required for paste simulation)
3. Use **⌘⇧V** to open clipboard history

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘⇧V` | Toggle clipboard panel |
| `↑` `↓` | Navigate items |
| `↵` | Paste selected item |
| `⇧↵` | Paste as plain text |
| `⌘C` | Copy to clipboard (without pasting) |
| `⌘1`–`⌘9` | Quick paste by position |
| `⌘⇧P` | Toggle pin |
| `⌘⌫` | Delete item |
| `⌘O` | Open URL / file |
| `⎋` | Close panel |

## Architecture

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

- **Rust** handles storage, search, and data integrity via SQLite with FTS5
- **SwiftUI** provides the UI with Raycast-style dual-pane layout
- **UniFFI** generates the Swift ↔ Rust bindings automatically

## Project Structure

```
Clipin/
├── rust/src/          # Rust core (storage, models, search)
├── Clipin/
│   ├── App/           # AppDelegate, entry point
│   ├── Views/         # SwiftUI views
│   ├── ViewModels/    # ClipboardViewModel
│   ├── Services/      # ClipboardMonitor, PasteService, HotKey
│   └── Generated/     # UniFFI auto-generated (gitignored)
├── scripts/
│   ├── build-rust.sh  # Build Rust + generate bindings
│   └── deploy.sh      # Deploy to /Applications with stable signing
└── project.yml        # xcodegen config
```

## License

MIT
