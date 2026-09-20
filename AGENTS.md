# Lexi

> ## 铁律：先用系统组件，绝不手写替代品
>
> **实现任何功能之前，先找 AppKit 组件和组件本身的 API。** NSScrollView/NSClipView/NSStackView/NSTableView/NSMenu/NSTrackingArea/Auto Layout…… 系统给的路径必须用系统的：行拖拽用 NSTableView 原生 drag & drop，右键菜单用 NSMenu，hover 用 NSTrackingArea，流式排布用 NSStackView，对齐用约束，输入框折叠/占位用 arrangedSubview 的隐藏收缩语义。
>
> **禁止自己手写这些能力**（手写 frame 排布、手写 hover 监视器、手写重排游标……）——历史上每一个"越改越多的怪 bug"（chip 重叠、占位丢失、hover 残留、行高跳动）都源自手写了组件已有的能力。手写只会把一个 bug 变成三个。没有现成组件的最小自定义（如 capsule 行视图的绘制）可以写，但凡 AppKit 有对应 API，一律走组件。

A macOS desktop app for English learning: selection toolbar, AI translation card, clipboard history, launcher, notebook, and SM-2 spaced-repetition review. **The entire product is one native Swift app** — no webview, no Rust backend, no Node toolchain.

## Architecture

```
Lexi/                            # all sources + the app bundle + build script
  build.sh                       # swiftc -O over App/ Design/ UI/ Data/ Services/ Debug/
                                 #   (find-collected) -> codesigned .app
                                 #   ./build.sh        compile + codesign
                                 #   ./build.sh run    build, relaunch
  LexiSelectionHelper.app/       # the product (bundle id com.lexi.selection-helper)
  main.swift                     # entry point (must keep this name: top-level code)

  App/                           # app shell — the one class decl + per-concern extensions
    SelectionToolbarHelper.swift # SelectionToolbarApp: stored props, lifecycle, status item,
                                 #   escape/dismissal, NWListener debug server bootstrap
    AppActions.swift             # action routing (handleAction switch), card-notes payload,
                                 #   clipboard-panel glue, saveVocab
    AppMonitors.swift            # global mouse monitors, far-cursor dismissal, click-outside hide
    AppTheme.swift               # card actions refresh, card chrome theme, input styling,
                                 #   settings window show

  Design/                        # the shared design system (no app state)
    ThemeTokens.swift            # CardTheme, PanelStyle, makePanelBackground, FileLog,
                                 #   tag colors, toolbar metrics
    LucideIcons.swift            # panelIcon + lucide SVG glyph table
    PanelControls.swift          # ToolbarButton, ToolbarDragHandle, KeyablePanel,
                                 #   HoverIconButton, HorizontalOnlyClip, CardResizeZone
    PanelDesign.swift            # panel tokens, refreshHoverTracking (the only NSTrackingArea
                                 #   site), snapshotPNG, PanelSearchField

  UI/
    Toolbar/ToolbarPanel.swift   # selection toolbar panel (build/place/show/hide/buttons)
    Card/                        # AI result card
      ResultCard.swift           # construction, show, panel tabs, note filters
      ResultCardRender.swift     # streaming events -> render, unified layout pass, placement
      ResultCardRuns.swift       # run-tab strip, input actions, submit/copy/save
      ResultCardNotes.swift      # notes/review tab logic + table delegates
      ResultCardViews.swift      # notes-row views (cell, table, pill, row view)
      ResultCardInputs.swift     # RunChipView, input text views
      CardPayloads.swift         # TCP payload structs + CardRun model (Status enum)
    Clipboard/                   # clipboard panel + notes tab
      ClipboardPanel.swift       # controller class decl, chrome, chips state, models
      ClipboardPanelChips.swift  # chip row: rebuild, NSStackView drag reorder, tag input/menus
      ClipboardPanelData.swift   # reload pipeline + NSTableView data source/delegate/DnD
      ClipboardPanelActions.swift# actions, context menus, keyboard routing, debug probes
      ClipCell.swift             # row cell family (measure, two-deck, inline rename)
      ChipViews.swift            # ChipPillView, ChipInputView, ChipsStackView
    Launcher/
      LauncherPanel.swift        # controller: lifecycle, chrome, keyboard, table pipeline
      LauncherSearch.swift       # query -> rows (folder grid, unified search, ranking)
      LauncherFolders.swift      # NSMetadataQuery Finder-tag scan, TCC, recents
      LauncherViews.swift        # row/cell/chip views (LauncherRowView shared with clipboard)
    Settings/
      SettingsWindow.swift       # native settings window (NSSplitViewController + SwiftUI)
      SettingsPanes.swift        # General/Appearance/AI/Shortcuts panes (+ LexiSettingsModel)
      SurfacePanes.swift         # per-surface config panes (toolbar/card/clipboard/launcher)
      StudyPanes.swift           # Vocabulary list + Review (flashcard/typing) panes
      NotebookPane.swift         # notebook + category manager
      ConfigsPane.swift          # AI feature editor

  Data/                          # persistence (no UI imports beyond Foundation)
    LexiStore.swift              # SQLite core: connection, settings KV, schema, migrations
    LexiStoreTables.swift        # features/words/notes/categories/tools tables + codecs
    ClipboardStore.swift         # clipboard history DB (FTS5, blobs, promote)
    SM2.swift                    # SM-2 spaced repetition

  Services/                      # headless engines + capture services
    AIService.swift              # streaming SSE AI runs + LexiTools + LexiSpeech (TTS)
    SelectionPipeline.swift      # LISTEN-only mouse tap + AX selection read chain
    ShortcutMonitor.swift        # global shortcuts (double-modifier detectors)
    ClipboardMonitor.swift       # 0.5s NSPasteboard.changeCount poller -> store
    LauncherAppIndex.swift       # installed-app index (scan, dedup, localized names)
    FileSearchService.swift      # Spotlight (MDQuery) file/folder search
    CalcEngine.swift             # launcher calculator (nil = not a calc)
    MarkdownText.swift           # markdown renderer (inline = AttributedString(markdown:))

  Debug/DebugServer.swift        # toolbar TCP listener + headless debug routes
```

## Data

Single shared SQLite database at `~/Library/Application Support/com.lexi.app/lexi.db`
(words, notes + note_categories, ai_features, settings KV, toolbar_tools action registry).
Notes carry exactly one category (`notes.category_id`); the settings Notebook pane,
clipboard panel tabs, and card notes tab all render from it. The legacy `tags`/
`note_tags` tables are retired — `migrateNoteCategories()` seeds categories from
them once on pre-cutover databases.
`LexiStore.ensureSchema()` folds the historical migrations 001-013 into one
idempotent statement set and seeds builtins; it runs at every startup.

## Runtime surfaces

- **Selection toolbar** — appears on text selection (AX read chain, never swallows events)
- **Result card** — per-run tabs, streaming markdown, save-to-vocabulary, notes/review tabs, pin
- **Clipboard panel** — Alt+V; paste-through promotes the item (the pasted
  item becomes the clipboard — standard clipboard-manager semantics)
- **Launcher** — double-Shift; empty query = folder grid (favorites/recents/Finder
  tags), typed query = unified folders+apps result list, led by a calculator
  answer row (Enter copies) when the query parses as math
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
- Dev-only HTTP routes (127.0.0.1, requires launching with `--debug-server`,
  e.g. `open LexiSelectionHelper.app --args --debug-server`): `/debug-shot?tab=<pane>`
  (renders a settings pane to /tmp as PNG), `/debug-clip-shot[?tab=notes|&rename=row|&plus=1]`
  (seeds marker layout probes, snapshots the clipboard panel, removes them;
  `tab=notes` opens a synthetic notes tab, `rename=row` opens the inline
  rename editor on that row and takes a second snapshot with the editor,
  `plus=1` seeds a full chip row and opens the ＋ input),
  `/debug-launcher-shot[?query=<urlencoded>|&select=row,chip]` (launcher snapshot —
  folder grid, or unified results/calc row for `query=`; chip selection repro),
  `/debug-state`, `/debug-paste-test`.
