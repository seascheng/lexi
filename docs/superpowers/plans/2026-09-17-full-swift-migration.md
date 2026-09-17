# Full-Swift Migration — Status & Handoff

Updated: 2026-09-17. Companion to `2026-09-16-launcher-panel-design.md`.

## State: all UI + AI + study + shortcuts are Swift-native. Tauri is a frozen shell.

The helper (`LexiSelectionHelper.app`) now owns: settings window (11 panes),
status item, AI streaming (SSE), TTS (Volcengine/say), SM-2 + study panes,
launcher/clipboard keyboard shortcuts, all panel rendering. React pages are
frozen — new work goes Swift-only. The Rust process remains only as:
selection monitor (mouse tap + AX reader + Cmd+C fallback), popup shortcut
(needs the AX reader), builtin tools (copy/search/note/handoff execution),
settings DB migrations, bundler.

## Key findings (do not re-derive)

1. **TCC trust resolves through the parent bundle.** The helper, living at
   `Lexi.app/Contents/Resources/native/LexiSelectionHelper.app`, CAN create
   session event taps — probe at startup logs `EVENTTAP probe: ok`
   (`probeEventTapAccess` in SelectionToolbarHelper.swift). The
   "must re-grant accessibility" fear was wrong. This unblocks the whole
   remaining migration.
2. **Swift CGEventTapLocation** has no `.cgSessionTap` in the current SDK —
   use `CGEventTapLocation(rawValue: 1)`.
3. **`CGEventTapEnable`** is replaced by `CGEvent.tapEnable(tap:enable:)`.
4. **Theme payload serde** must be `rename_all = "camelCase"` (Swift
   Decodable silently nils snake_case optionals — cost a session).
5. **Watchdog + QUITTING flag**: helper Quit posts `quit-lexi`; Rust sets
   `QUITTING` so the watchdog never resurrects the helper mid-shutdown.

## Migrated (commits 18a9864 → 0f3008a)

| Layer | Swift home | Notes |
|---|---|---|
| Settings window | SettingsWindow.swift | TinyCast recipe: NSWindow fullSizeContentView, NSSplitViewController, AppKit toolbar `[.sidebarTrackingSeparator, back, forward]`, `isNavigational` items, inline title = tab, unified bar, titlebar NOT transparent |
| Panes | SettingsPanes / StudyPanes / ContentPanes / SurfacePanes | General, Appearance, AI, Shortcuts, Vocabulary, Review, Notebook, Configs, Toolbar, Card&Notes, Clipboard, Launcher |
| LexiStore | LexiStore.swift | Same `com.lexi.app/lexi.db`; settings KV, words (+SM-2), notes, ai_features CRUD, toolbar_tools blob, excluded apps, card frame |
| SM-2 | SM2.swift | 12/12 vectors vs Rust formula |
| AI | AIService.swift | URLSession `bytes.lines` SSE, 40ms coalescing, thinking toggle, translation_json + auto-save; `showResultCard` is the single run orchestrator |
| TTS | AIService.swift (LexiSpeech) | Volcengine NDJSON → AVAudioPlayer, `say` fallback |
| Shortcuts | ShortcutMonitor.swift | Active session tap; launcher+clipboard in-process; clipboard combo DROPS (Alt+V √); typing-guarded double press |
| Status item | SelectionToolbarHelper.swift | ✨ menu: Settings/Launcher/Quit; quit coordinates via `quit-lexi` + `QUITTING` flag |
| Card review tab | SelectionToolbarHelper.swift | `loadReviewWord()`/`gradeClicked` local (panel-review/review-grade retired) |

## Remaining

### 1. Selection pipeline (blocked on user validation)

Rust home: `native_toolbar.rs` — mouse tap ~line 1576-1715 (down origin
tracking for drag-detection, mouse-up → excluded apps → self-window checks
→ AX read chain `read_selected_text_via_ax_text` → `read_web_area_selection`
(AXWebArea DFS, WEB_AREA_CHILD_SEARCH_DEPTH) → menu-copy
(`read_selected_text_via_menu`) → Cmd+C (`handle_copy_for_toolbar`,
5s last-copied cache)) + `show_toolbar` posting `/show`.

Protocol: port in two layers, dual-track with helper-side dedup (drop a
`/show` if an identical text arrived <500ms ago — Rust and Swift will both
fire during the overlap window).

- Layer 1: mouse-up + excluded apps + AX direct read (covers native apps)
- Layer 2: WebArea DFS + menu-copy + Cmd+C fallback (browsers, Ghostty/Zed)

`trigger_popup_with_selection` (line ~1979) migrates with Layer 2 (popup
shortcut prefill depends on the reader).

### 2. Actions table normalization (fold into cutover)

`toolbar_tools` JSON blob stays the storage format while Rust readers live
(`read_tool_config`, `panel_config_items`). At cutover: create `actions`
table (id, name, icon, toolbar_enabled, toolbar_order, panel_enabled,
panel_order, config JSON), migrate once in Swift, delete the Rust readers
with Tauri.

### 3. Cutover

- Port remaining builtin tools (copy/search/note/handoff) or accept
  in-DB tool configs and reimplement: copy=NSPasteboard, search=URL open,
  note=INSERT notes (tag Tmp), handoff=activate + paste (needs the Rust
  text_injection port — NSPasteboard lease + CGEvent paste, see
  `text_injection.rs`)
- Delete: src/ (React ~3.3k), src-tauri Rust ~5k, Node toolchain
- Packaging: xcodebuild + XcodeGen (copy TinyCast `project.yml` shape);
  build.rs swiftc invocation is the reference for flags
  (`-framework SwiftUI/AVFoundation/Network/AppKit -lsqlite3`)
- Signing: `Apple Development: chengweipeng123@163.com (D8YJ3P5B53)`
  (see build.rs), `--options runtime`

## Verification loop for every deploy

`npm run tauri build` → `pkill -f "Lexi.app/Contents/MacOS/lexi"` →
`open .../target/release/bundle/macos/Lexi.app` → grep
`/private/tmp/lexi-selection-helper.log` for the new
`SHORTCUT tap installed` / probe lines → exercise: selection→toolbar→
Translate (streamed), double-Shift launcher, Alt+V clipboard (no "√"
typed), Review grading, settings live-apply.
