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

1. **Event-tap userInfo must be recovered with
   `Unmanaged<T>.fromOpaque(userInfo).takeUnretainedValue()`** — never
   `assumingMemoryBound(to:).pointee`. `toOpaque()` is the instance's own
   address; `.pointee` reinterprets the object header (isa + refcount) as
   a reference → PAC-fault SIGSEGV on first callback. Cost: a 30-minute
   crash-loop that masqueraded as "selection stopped working" (7 crash
   reports, d9d74ef fixed).
2. **AX reads never in the tap callback** — hand to a worker queue; set
   `AXUIElementSetMessagingTimeout` ~0.3s; re-arm on
   `tapDisabledByTimeout`.
3. **TCC trust resolves through the parent bundle.** The helper, living at
   `Lexi.app/Contents/Resources/native/LexiSelectionHelper.app`, CAN create
   session event taps — probe at startup logs `EVENTTAP probe: ok`
   (`probeEventTapAccess` in SelectionToolbarHelper.swift). The
   "must re-grant accessibility" fear was wrong.
4. **Swift CGEventTapLocation** has no `.cgSessionTap` in the current SDK —
   use `CGEventTapLocation(rawValue: 1)`.
5. **`CGEventTapEnable`** is replaced by `CGEvent.tapEnable(tap:enable:)`.
6. **Theme payload serde** must be `rename_all = "camelCase"` (Swift
   Decodable silently nils snake_case optionals — cost a session).
7. **Watchdog + QUITTING flag**: helper Quit posts `quit-lexi`; Rust sets
   `QUITTING` so the watchdog never resurrects the helper mid-shutdown.

## Migrated (commits 18a9864 → 0f3008a)

| Layer | Swift home | Notes |
|---|---|---|
| Settings window | SettingsWindow.swift | TinyCast recipe: NSWindow fullSizeContentView, NSSplitViewController, AppKit toolbar `[.sidebarTrackingSeparator, back, forward]`, `isNavigational` items, inline title = tab, unified bar, titlebar NOT transparent |
| Panes | SettingsPanes / StudyPanes / ContentPanes / SurfacePanes | General, Appearance, AI, Shortcuts, Vocabulary, Review, Notebook, Configs, Toolbar, Card&Notes, Clipboard, Launcher |
| LexiStore | LexiStore.swift | Same `com.lexi.app/lexi.db`; settings KV, words (+SM-2), notes, ai_features CRUD, toolbar_tools blob, excluded apps, card frame |
### 1. Selection pipeline (Layer status)

- ✅ Mouse tap (listen-only, worker queue, 0.3s AX timeout, dedup gate)
- ✅ Tier 1/2/3 read chain: kAXSelectedText → AXValue+range slice
  (UTF-16 exact) → web-area markers (9b043de)
- ✅ Cmd+C copied-text fallback with 5s freshness (431a418)
- ⬜ Layer 2c: menu Copy (AXPress Edit→Copy, pasteboard borrow/restore,
  ClipboardMonitor suspend coordination — same-process now, no TCP lease)
  and the session-tap Cmd+C injection (full 4-event modifier sequence,
  `combinedSessionState` + hardware bit). Both stay RUST-ONLY during
  dual-track (dedup absorbs; Ghostty/Zed keep working); port only at
  tap retirement. Rust bodies: read_selected_text_via_menu ~2399,
  post_cmd_c_and_read ~2541.
- Rust also keeps: popup shortcut (trigger_popup_with_selection ~1979),
  mouse-up drag-detection rich logic, handoff tool.
- Protocol: dual-track with helper-side dedup (600ms same-text gate) —
  validated live: Swift crash-looped for 30min while Rust kept every
  selection working.
(The original two-layer protocol above is superseded by the status list;
Rust bodies for the remaining tiers: read_selected_text_via_menu ~2399,
post_cmd_c_and_read ~2541, trigger_popup_with_selection ~1979.)
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
