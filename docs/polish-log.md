# Clipin Polish Log

## 2026-03-27

### Preview detail stage refinement

- Split preview-specific surfaces out of the old shared `grouped` role so the detail pane can stay elegant without adding another obvious card layer. `contentStage` now carries the main preview, while `metadata` stays as a quieter companion block instead of reusing the heavier settings-style grouping surface.
- Tightened the right pane proportions instead of adding more chrome: smaller outer/detail insets, slightly smaller inner radii, and lighter stage contrast keep the preview framed without making it feel boxed in.
- Let visual content breathe a little more by shaving stage padding and slightly increasing image preview height, while also softening media shadows so the content remains the focus.
- Followed up on the next review by separating “container inset” from “object width”: the preview stage and metadata block now keep their own horizontal object inset inside the detail pane, so the right side stops reading as edge-to-edge even though it still uses a single shared detail surface.
- Shrunk metadata density instead of only changing fonts: tighter block inset, smaller value typography, and narrower grid spacing give vertical space back to the preview stage so the bottom info block no longer outweighs the content it describes.
- Rebalanced the footer as a fixed-height command strip and reduced the Paste CTA's internal padding/icon size, so the bottom bar keeps one height across normal and empty/filter states instead of being stretched by the selected-item callout.

### Window-aware keyboard routing and structural UI cleanup

- Moved keyboard navigation from a panel-first assumption to a window-aware router in `AppDelegate`, so `↑↓` now go to the active context instead of being silently stolen by the main panel. Settings uses a dedicated `SettingsNavigationModel`, which restores arrow-key sidebar switching without falling back to `List(selection:)`.
- Removed action-palette query state and filtering from `ClipboardViewModel`, the palette header, and the keyboard monitor. `⌘K` is now a static command sheet with arrow navigation, Enter to run, and Esc to close, while plain typing/backspace/tab are swallowed so input never leaks back into the main search field.
- Reworked the main list spacing skeleton instead of only retinting selection: the sidebar now has a section-level gutter and scrollbar reserve, so selected rows no longer read as flush to the container edges and the main list finally shares the same breathing room as the action palette.
- Restored one quiet inner stage to the detail pane and brought metadata back as a grouped block rather than a flat inline grid. The right side now has a clear content stage plus a compact info group, which keeps the previous version's anchored finish without returning to stacked two-line fields or dividers.
- Slightly strengthened the native theme selection fill/stroke so the default theme's selected row reads more decisively once the spacing skeleton is in place.

### Content-first attention hierarchy in the main panel

- Stopped treating the issue as isolated tint tuning and introduced a shared `ClipinPanelHierarchy` semantic model for `scope`, `selection`, and `command`, so the panel's task hierarchy now lives in one place instead of leaking through ad-hoc color picks.
- Demoted the top filter pills to quiet scope controls, rebuilt list selection as a theme-tinted selected surface instead of a neutral row plus side rail, and recast the footer `Paste to…` chip as a command hint rather than the primary visual button.
- Simplified the right preview pane back to a single surface after visual review: removed the extra nested preview shell, dropped the hero-mode typography, and kept text/URL preview content on one consistent reading size so the experience stays continuous while navigating.
- Removed the hard divider approach after review and regrouped preview metadata with subtle layered surfaces and whitespace instead, so the lower info block still reads as a separate group without breaking the panel into line-cut regions.
- Rebuilt the info panel from stacked two-line fields into a compact inline metadata grid with a dedicated `InfoItem` model, so secondary details use less vertical space and behave more like dense metadata than mini content blocks.
- Pulled the action palette back into the same design family as the main panel by sharing rounded-surface primitives, keycap chrome, and the same quiet selected-row language instead of letting the palette keep its own independent glass skin.
- Followed up with a structural unification pass after visual review: replaced repeated per-view surface recipes with shared `ClipinSurfaceBackground` roles, so sidebar/detail/control/footer surfaces now come from one semantic mapping instead of ad-hoc material constants in each screen.
- Matched the main list spacing to the action palette by increasing shared row inset, moving selection away from the container edges, and reusing one `ClipinSelectableRowBackground` for the main panel, action palette, and settings sidebar.
- Removed the preview footer card and turned metadata into an inline group under the content stage, so the right pane keeps one clear focal object while still exposing source/type/count/dimension details compactly.
- Rebuilt Settings and Permission windows onto the same design grammar: custom settings sidebar rows instead of `List` chrome, grouped surfaces instead of `Divider()`, and theme-aware recorder/notice surfaces so edge-case windows no longer feel like a different app.

Acceptance:

- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -derivedDataPath /tmp/ClipinDerived build`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -derivedDataPath /tmp/ClipinDerivedRelease build`

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

## 2026-03-25

### Palette architecture, hierarchy cleanup, and Cmd+K responsiveness

- Moved action-palette state into `ClipboardViewModel` so opening, navigating, executing, and dismissing the palette all use one source of truth instead of ad-hoc view mutations.
- Rebuilt the `⌘K` palette as a compact anchored card with fixed width, semantic action groups, cached actions, and keyboard navigation that no longer depends on preview detail loading.
- Removed the full-panel animation path for palette toggling and tightened the main shell into distinct header, content, and footer surfaces so the current selection stays primary and the chrome stops competing with content.
- Softened the left-list selection treatment, reduced full-window purple tinting, and kept the preview card visually above the shell without turning the actions panel into a second screen.

Acceptance:

- `cd rust && cargo test --lib`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

### Rust toolchain alignment for macOS deployment target

- Added a repository `rust-toolchain.toml` pinned to `stable` so local shells, Xcode build scripts, and future CI runs resolve the same Rust standard library baseline.
- Updated `scripts/build-rust.sh` to invoke Cargo and rustc through `rustup` instead of whichever Homebrew binary happens to be first on `PATH`.
- Eliminated the `built for newer macOS version (26.0) than being linked (15.0)` linker warnings caused by mixing an Xcode deployment target of 15.0 with a Homebrew Rust standard library built for macOS 26.0.

Acceptance:

- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

### Soft-surface UI pass inspired by ChatGPT for Mac and App Store

- Removed the remaining visible dividers and card strokes from the main shell, replacing them with softer surface contrast, shadow depth, and white-space separation.
- Tuned the search bar, sidebar rows, bottom action area, and preview metadata region toward a calmer macOS look where sections feel embedded in one window rather than boxed into separate panels.
- Reworked the `⌘K` action palette into a lighter glassier sheet with higher transparency, grouped spacing instead of separators, and a single strong focus state instead of row-by-row chrome.
- Followed up with a de-bloom pass after visual review: reduced the milky white glow on the shell, widened the window, pushed the sidebar darker than the preview canvas, and made text previews read more like content than code.
- Increased the hierarchy contrast instead of adding lines: stronger sidebar tint, cleaner white preview surface, slightly larger typography in list/footer/filter pills, and more decisive metadata contrast in the preview footer.

Acceptance:

- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build`

## 2026-03-26

### Unified settings chrome and primary paste CTA

- Rebuilt the settings window onto the same glass palette and material layering as the clipboard panel so both surfaces now read as one product instead of two visual systems.
- Replaced the footer's generic tinted badge for `Paste to …` with a dedicated primary call-to-action that uses theme-aware gradients, a separate keycap layer, and spring-driven press feedback.
- Moved the footer CTA tinting into `ClipinTheme` so `Mist`, `Graphite`, and `Sunrise` can each carry their own emphasis color without falling back to a generic system accent.

Acceptance:

- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -derivedDataPath ./.derived-data build`

### Semantic interaction system and preference-window cleanup

- Promoted interaction colors and motion into shared semantic tokens instead of leaving row selection, hover, search pills, palette focus, and notice states on ad-hoc `accentColor` and per-view timing curves.
- Simplified the main panel hierarchy by flattening the search surface, softening nested metadata chrome, and making list, footer, and palette emphasis all read from the same visual language.
- Tuned the settings window toward a more native macOS preference feel: monochrome sidebar icons, lighter content cards, subtler separators, and a less branded overall chrome.
- Pulled the shortcut recorder and accessibility permission window back into the same glass/material family so edge-case windows no longer feel like a second app.

Acceptance:

- `cd rust && cargo test --lib`
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release -derivedDataPath ./.derived-data build`
