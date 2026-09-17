# Lexi

A macOS desktop app for English learning: selection toolbar, AI translation card, clipboard history, launcher, notebook, and SM-2 spaced-repetition review. **The entire product is one native Swift app** — no webview, no Rust backend, no Node toolchain.

## Architecture

```
Lexi/                            # all sources + the app bundle + build script
  build.sh                       # swiftc -O over the sources -> codesigned .app
                                 #   ./build.sh        compile + codesign
                                 #   ./build.sh run    build, relaunch
  LexiSelectionHelper.app/       # the product (bundle id com.lexi.selection-helper)
  SelectionToolbarHelper.swift   # app delegate: lifecycle, shared state, action routing
  ToolbarPanel.swift             # selection toolbar panel (build/place/show/hide/buttons)
  ResultCard.swift               # result card: runs, tabs, streaming render, notes/review tabs
  ResultCardViews.swift          # card view types: rows, cells, table, dropdown, chips
  DebugServer.swift              # toolbar TCP listener + headless debug routes
  SelectionPipeline.swift        # LISTEN-only mouse tap + AX selection read chain
                                 #   (selected text direct -> range slice -> WebArea)
  ShortcutMonitor.swift          # global shortcuts: double-Shift launcher, Alt+V clipboard,
                                 #   double-Ctrl popup card, plain Cmd+C copy fallback
  ClipboardMonitor.swift         # pasteboard poller with suspend/resume lease
  ClipboardStore.swift           # clipboard history DB
  ClipboardPanel.swift           # clipboard panel UI + ClipboardPaster (activation + paste)
  LauncherPanel.swift            # spotlight-style launcher (NSMetadataQuery tags)
  PanelDesign.swift              # shared panel chrome/theme tokens
  PanelCoordinator.swift         # audit-only trail of the active surface (no policy)
  AIService.swift                # streaming SSE AI runs + LexiTools + LexiSpeech (TTS)
  LexiStore.swift                # SQLite (shared lexi.db): settings, words, notes,
                                 #   ai_features, toolbar_tools/actions, ensureSchema()
  SM2.swift                      # SM-2 spaced repetition
  StudyPanes.swift               # Vocabulary expansion list + Review flashcards
  ContentPanes.swift             # Notebook + Configs (AI feature editor)
  SurfacePanes.swift             # per-surface config panes (toolbar/card/clipboard/launcher)
  SettingsPanes.swift            # General/Appearance/AI/Shortcuts settings panes
  SettingsWindow.swift           # native settings window (NSSplitViewController + SwiftUI)
  MarkdownText.swift             # lightweight native markdown renderer
  main.swift                     # entry point
```

## Data

Single shared SQLite database at `~/Library/Application Support/com.lexi.app/lexi.db`
(words, notes, tags, ai_features, settings KV, toolbar_tools action registry).
`LexiStore.ensureSchema()` folds the historical migrations 001-013 into one
idempotent statement set and seeds builtins; it runs at every startup.

## Runtime surfaces

- **Selection toolbar** — appears on text selection (AX read chain, never swallows events)
- **Result card** — per-run tabs, streaming markdown, save-to-vocabulary, notes/review tabs, pin
- **Clipboard panel** — Alt+V; paste-through restores the user's pasteboard
- **Launcher** — double-Shift; tagged folders + apps
- **Settings window** — native AppKit/SwiftUI; changes apply in-process and persist to the DB
- **Status item** — Settings / Launcher / Quit

Launch at login uses SMAppService (Settings → General → Startup).

## Build

```bash
cd Lexi
./build.sh        # compile + codesign LexiSelectionHelper.app
./build.sh run    # build, kill the running instance, launch
```

Signing identity lives in build.sh. The bundle id (com.lexi.selection-helper)
is load-bearing: Accessibility and Screen Recording TCC grants are tied to it —
do not change it casually.

## Debugging

- Helper log: `/private/tmp/lexi-selection-helper.log`
- The helper's toolbar HTTP server exposes dev-only routes: `/debug-shot?tab=<pane>`
  (renders a settings pane to /tmp as PNG), `/debug-state`, `/debug-paste-test`.
