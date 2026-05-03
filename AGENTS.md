1. Please evaluate my proposal based on the current implementation and target requirements before executing it, rather than blindly following.
2. Fixing bugs must involve upward exploration, adopting a general solution from the root cause instead of workaround, cleaning up old code at last.
3. For implementing new feature, it is essential to ensure code reusability and follow the current file directory based on the existing architecture.
4. We pursue the separation of duties while avoiding excessive complexity and abstraction; we aim for clean code while avoiding fragmentation.

# Englist Tool

A macOS desktop app for English learning with AI-powered translation, vocabulary management, and spaced repetition review.

## Tech Stack

- **Desktop:** Tauri 2 (Rust) + macOS native APIs (core-graphics, Accessibility, CGEvent)
- **Frontend:** React 18 + TypeScript + Vite 5
- **UI:** Tailwind CSS 3 + custom design tokens (CSS variables) + Lucide icons
- **Storage:** SQLite via `tauri-plugin-sql` (localStorage fallback for browser dev)
- **Native toolbar:** Standalone Swift app (NSPanel) communicating with Rust via TCP

## Architecture

```
src/                          # Frontend (React + TypeScript)
  main.tsx                    # Entry point, detects ?window= param
  App.tsx                     # Routes: MainWindow | TranslationWindow
  types.ts                    # All TypeScript type definitions
  pages/
    VocabularyPage.tsx        # Word list with search, filter, pagination
    ReviewPage.tsx            # SM-2 flashcard review
    FeaturesPage.tsx          # AI feature CRUD editor
    SettingsPage.tsx          # Theme, display mode, AI API config
  components/
    translation/
      TranslationWindow.tsx   # Main translation popup/bar (~1250 lines)
      FloatingFrame.tsx       # Drag region + resize handles for popup
      TranslationResultPanel.tsx  # Single translation result display
      QuickTranslate.tsx      # Inline translation form (unused in routing)
    ui/                       # Shared UI components (Button, Card, Field, etc.)
  lib/
    database.ts               # Data layer (SQLite / localStorage)
    ai.ts                     # AI integration via Tauri commands
    sm2.ts                    # SM-2 spaced repetition algorithm
    translation.ts            # Popup window positioning and state
    appearance.ts             # Theme, transparency, Liquid Glass
    platform.ts               # Runtime detection, date helpers
    defaults.ts               # Default settings and feature templates
    export.ts                 # JSON/CSV export
    cn.ts                     # clsx + tailwind-merge utility

src-tauri/                    # Backend (Rust)
  src/
    lib.rs                    # Tauri setup: plugins, commands, tray menu
    native_toolbar.rs         # macOS selection toolbar (~930 lines)
                               # - Swift helper launch, TCP IPC
                               # - CGEventTap mouse monitoring
                               # - Clipboard probe for selected text
                               # - Window drag detection
    cursor.rs                 # Mouse position via AppleScript
    commands/
      ai.rs                   # OpenAI-compatible API calls
      speech.rs               # macOS `say` TTS
      window.rs               # Popup resize/height via core-graphics
  native/
    SelectionToolbarHelper.swift  # Standalone Swift toolbar app (~560 lines)
  migrations/                 # SQLite migrations (001-006)

  Windows (tauri.conf.json):
    main       -- 1180x820, main app window
    float_bar  -- 980x260, always-on-top, transparent, no decorations
    popup_card -- 360x360+, always-on-top, transparent, no decorations
```

## Routing

No router library. URL-param based:
- `index.html` → MainWindow (4 sidebar pages: Vocabulary, Review, Features, Settings)
- `index.html?window=float_bar` → TranslationWindow (floating bar mode)
- `index.html?window=popup_card` → TranslationWindow (popup card mode)

## Database Schema

- **words**: id, word, translation, pos, definition, example, status (new/learning/mastered), review fields (SM-2), entry_type, source_text, note
- **settings**: key-value pairs
- **ai_features**: id, name, kind, prompt_template, output_mode, icon, speech_enabled, sort_order, etc.

## Key Patterns

- **Dual runtime**: All `lib/*.ts` modules branch on `isTauriRuntime()` — Tauri path uses `invoke()` / SQLite; browser path uses mocks / localStorage
- **Tauri events**: Native toolbar communicates selected text to frontend via `emit()` / `listen()`
- **Theme system**: CSS custom properties (`--color-background`, `--color-panel`, etc.) toggled via `data-theme` attribute; macOS Liquid Glass integration
- **AI features**: User-defined prompts with `{{text}}` / `{{targetLanguage}}` templates; supports translation_json and plain_text output modes
