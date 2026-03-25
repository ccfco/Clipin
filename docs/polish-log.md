# Clipin Polish Log

## 2026-03-24

### Keyboard navigation and double-click paste

- Added arrow-key navigation from the search field into the list, with Enter to paste and Escape to close.
- Added automatic scrolling to keep the current selection visible while navigating.
- Added double-click paste on list rows for pointer-driven workflows.
- Refactored list rendering into a smaller SwiftUI subview to keep Swift 6 compilation stable.

Acceptance:

- `cd rust && cargo test --lib`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

### Settings, cleanup, and import/export

- Added a real settings window with launch-at-login, retention policy, max-history cap, and configurable global shortcut recording.
- Added automatic cleanup for unpinned items older than the retention window and for unpinned history beyond the configured cap.
- Added JSON export/import with preserved timestamps, pinned state, and embedded image payloads for migration.
- Wired cleanup to run on launch, after new clipboard captures, and after imports or policy changes.

Acceptance:

- `cd rust && cargo test --lib`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

### App icon and UI polish

- Added a custom macOS app icon asset set and connected resources into the Xcode project definition.
- Refined the main panel with a layered material background, cleaner list cards, richer row metadata, and a more polished preview layout.
- Added a direct settings entry point from the main panel toolbar.

Acceptance:

- `xcodegen generate`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

### Performance, settings access, and UI reset

- Split list loading from detail loading so the main list only fetches lightweight previews while the right pane loads the full clipboard item on demand.
- Moved clipboard persistence off the main thread and switched long-text preview rendering to `NSTextView` so large clipboard entries no longer block the panel for multiple seconds.
- Replaced the fragile settings selector path with a dedicated native settings window owned by `AppDelegate`, which opens reliably from the panel.
- Reworked the main panel visuals toward a calmer macOS-native look with neutral surfaces, subtler selection states, and less decorative chrome.

Acceptance:

- `cd rust && cargo test --lib`
- `xcodegen generate`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`
