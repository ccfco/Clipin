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
- **Keyboard-first** — Navigate with arrow keys, paste with Enter, and quick-paste the first 9 visible items with always-on ⌘1-9 badges
- **Compact action palette** — Press ⌘K for a focused command sheet with full keyboard control
- **System Quick Look** — Press `Space` on an idle search box or `⌘Y` while filtering for a full-size native preview without leaving the keyboard flow
- **Layered escape flow** — Press `Esc` to clear active search/type filters first, then close the panel once you're back at the full list
- **Smart dedup** — Repeated copies are merged, tracking copy count and timestamps
- **Rich preview** — Right pane shows full content, metadata, image thumbnails, search highlights, and hex color swatches
- **Finder multi-file aware** — Copy multiple files at once and Clipin preserves, previews, reopens, and pastes the full selection
- **Color detection** — Hex colors (#RGB / #RRGGBB) are shown with a color swatch, RGB, and HSL values
- **Pin important items** — Pinned entries stay at the top, never expire
- **Type filtering** — Filter by Text, Image, File, or URL
- **Plain text paste** — ⇧Enter strips formatting
- **Copy without paste** — ⌘C puts item back on clipboard without pasting
- **Context menu** — Right-click items for Paste, Pin/Unpin, Delete
- **Smooth animations** — Fade in/out panel transitions
- **Long-term storage** — Keep clipboard history for 1–5 years with configurable retention
- **Privacy-first** — All data stored locally in SQLite, and concealed/transient clipboard payloads are skipped automatically

## Screenshot

> TODO: Add screenshot

## Installation

### Build from Source

Requires: rustup-managed Rust stable, Xcode 16+, [xcodegen](https://github.com/yonaskolb/XcodeGen)

```bash
# Clone
git clone https://github.com/user/Clipin.git
cd Clipin

# Install the repository Rust toolchain
rustup toolchain install stable

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
| `Space` | Quick Look the selected item when the search box is empty |
| `⌘Y` | Quick Look the selected item even while search text is active |
| `⌘1`–`⌘9` | Quick paste the first 9 visible items in the current list |
| `⌘⇧P` | Toggle pin |
| `⌘⌫` | Delete item |
| `⌘O` | Open URL / file |
| `⌘K` | Toggle action palette |
| `Tab` / `⇧Tab` | Cycle type filter forward / backward |
| `⌘,` | Open settings |
| `⎋` | Clear search/type filters first, then close the panel |

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
