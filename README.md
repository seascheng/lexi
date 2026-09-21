<div align="center">

<img src="images/logo.png" alt="Lexi" width="88" height="88" />

### Lexi

**A small native macOS tool: selection AI actions, clipboard + notes, favorite folders. Few features — the ones you use every day.**

<sub>Swift · AppKit · SQLite — no webview, no Electron, no Node toolchain</sub>
<sub>v0.1.0 · macOS 13+ · ad-hoc signed</sub>

</div>

## What you get

### Selection → Action Panel

Select text anywhere and a small pill appears. One click opens the action panel.

- **AI translate built in** — streaming results rendered as native markdown, one tab per run, follow-up input, pin, text-to-speech.
- **Extensible to any AI action** — the Configs pane turns any prompt into a toolbar/card action (rewrite, explain, extract, your own study drills — prompt, output mode, target language, icon, sort order). The toolbar and card pick them up live.
- **Language learning lives in the same card** — save the word to vocabulary, file the sentence as a note, or flip to the Review tab: an SM-2 flashcard flow (reveal, then Again / Hard / Good / Easy).
- **Restrained by design** — Lexi never rewrites your text in place. No auto-correction, no auto-replacement, no "accept all changes". You read the result, you choose what to do with it. The tool suggests; you decide.

<div align="center">
<img src="images/toolbar.png" alt="The selection toolbar: a small pill with icon actions floating over selected text" width="360" />
<img src="images/card.png" alt="Action panel in Review mode: a flashcard with Again/Hard/Good/Easy grading" width="380" />
<br />
<sub>Left: the selection pill. Right: the action panel's Review tab — one of the language-learning methods.</sub>
</div>

### Clipboard + Notes, one search box

- **`⌥V` opens the panel; ⏎ pastes through** — the pasted entry is promoted to the clipboard, standard clipboard-manager semantics.
- **Search across clipboard AND notes** — one keyword box queries both the full history and every note you've filed.
- **Note categories are yours to define** — create the kinds that match how you work (Note, Password, API_KEY, Command, anything); every note carries exactly one, and the same categories drive the card's notes tab.
- Pin what you use often; file links and images are kept as first-class entries.

<div align="center">
<img src="images/clipboard.png" alt="Clipboard panel: category chips, keyword search, history entries, entry context menu, footer shortcuts" width="420" />
<br />
<sub>Category chips, unified search, per-entry context menu, ⌘P pin · ⏎ paste.</sub>
</div>


### Launcher: your folders, front and center
- **The highlight: a custom grid of your favorite folders** — pin the five system folders or your own; folders tagged in Finder group under their real tag colors, so 个人 / 工作 / 项目 land where you expect them.
- Everything else stays simple: typing searches files and apps, and a query that parses as math gets a calculator row (Enter copies).

<div align="center">
<img src="images/launcher.png" alt="The Lexi launcher: a folder grid with Favorites and Finder tag groups in their real tag colors" width="640" />
<br />
<sub>Favorites plus Finder tag groups (个人 green, 项目 blue) in their real tag colors. Double-Shift, recordable — even <code>⌘Space</code>.</sub>
</div>

### Finder right-click

A Lexi submenu in Finder: copy path, new file, open in terminal, open in editor — each action toggles independently in Settings → Finder.

<div align="center">
<img src="images/finder_menu.png" alt="Finder right-click Lexi submenu: copy path, new file, open in terminal, open in editor" width="300" />
</div>

## Why so small

Most "enhancement" tools grow a feature for every request. Lexi goes the other way: text actions, clipboard, folders, a Finder menu — each one earns its place by being used daily. Nothing auto-applies, nothing interrupts; every surface opens with a keystroke and leaves when you're done. Settings is one native window (twelve panes) and everything applies live.

<div align="center">
<img src="images/settings-general.png" alt="Settings window, General pane" width="280" />
<img src="images/settings-vocabulary.png" alt="Settings window, Vocabulary pane" width="280" />
<img src="images/settings-review.png" alt="Settings window, Review pane" width="280" />
<br />
<sub>Settings: General, Vocabulary, Review.</sub>
</div>

## Install

Grab the DMG from [**Releases**](https://github.com/seascheng/lexi/releases/latest), drag Lexi to Applications.

<sub>macOS 13+ · Apple Silicon (arm64) · ad-hoc signed: on first open, right-click the app → **Open** (once)</sub>

Grant **Accessibility** and **Screen Recording** when prompted — the selection reading chain and the global shortcuts need them, and both grants are tied to the bundle id (`com.lexi.selection-helper`). Launch at login via **Settings → General → Startup**.

## Build

```sh
cd Lexi
./build.sh          # swiftc -O over the sources -> codesigned LexiSelectionHelper.app
./build.sh run      # build, kill the running instance, launch
./release.sh        # build -> DMG -> push -> GitHub release
```

- Helper log: `/private/tmp/lexi-selection-helper.log`
- Headless UI snapshots: launch with `--debug-server`, then `POST /debug-shot?tab=<pane>`, `/debug-launcher-shot[?query=]`, `/debug-clip-shot`, `/debug-card-shot`, `/debug-toolbar-shot` on `127.0.0.1:43877` — every screenshot in this README was captured through these routes.

## Architecture

```
Lexi/
  App/        app delegate: lifecycle, shared state, action routing
  Data/       LexiStore (SQLite) · ClipboardStore · FinderSyncConfig
  Debug/      headless debug server (the /debug-* routes)
  Design/     theme tokens · lucide icon set · logo
  Services/   AI SSE service · selection pipeline · shortcut monitor · clipboard monitor
  UI/         Toolbar / Action card / Clipboard / Launcher / Settings panes
  FinderSync/ Finder right-click extension (.appex, zero IPC with the main app)
```

One native Swift app — the entire product is AppKit; the only compiled extras are the FinderSync extension and the two SQLite stores. Long-lived invariants live in `AGENTS.md` and are binding.

---

<div align="center">
<sub>

Icons from [Lucide](https://lucide.dev) · spaced repetition by SM-2 · v0.1.0

</sub>
</div>
