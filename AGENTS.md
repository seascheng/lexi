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


<claude-mem-context>
# Memory Context

# [englist-tool] recent context, 2026-05-03 1:44pm GMT+8

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (13,369t read) | 0t work

### May 3, 2026
496 11:41a 🔄 Removed ToolbarPage import from App.tsx during consolidation
497 " 🔄 Removed toolbar navigation item and page type from App.tsx
498 " 🔄 Removed toolbar page routing logic from App.tsx
499 " 🔄 Added config property to ToolbarTool interface for tool-specific settings
500 " 🔄 Updated database layer to persist and load tool config properties
501 11:42a 🔄 Updated saveToolbarTools to persist tool config property
S189 Toolbar drag-and-drop fixed with Pointer Events refactor (May 3 at 11:43 AM)
502 11:45a 🔴 Toolbar configuration drag-and-drop functionality broken
503 " 🔴 Enable button styling broken in toolbar configuration
504 " 🟣 Toolbar preview styling optimization requested
505 11:49a 🔴 TypeScript ref type error resolved with dual approach
506 " 🔵 Toolbar styling system uses native Swift theming
508 " 🔵 Native toolbar uses specific 34x30 pixel segments with 16px icons
509 " 🔴 Fixed drag-and-drop functionality and toggle button styling
510 " 🟣 Toolbar preview redesigned to match native macOS appearance
507 11:50a 🔵 Native toolbar implementation details revealed
514 11:51a 🔴 Drag-and-drop reordering still non-functional in toolbar configuration
511 11:52a 🔴 Implemented proper React drag-and-drop event handling
512 " 🔴 Fixed toggle button styling and interaction
513 " 🟣 Toolbar preview redesigned to match native macOS toolbar exactly
515 " 🔴 Drag-and-drop event handling updated with proper dataTransfer API
516 11:56a 🔄 Drag-and-drop refactor from HTML5 API to pointer events approach
517 11:57a 🔄 Implemented pointer events-based drag-and-drop to replace HTML5 API
519 " 🔄 Pointer events drag-and-drop implementation completed successfully
518 " 🔵 TypeScript compilation passed successfully after pointer events refactor
S190 Clean up Extract/capture feature code across entire project - toolbar and popup panel no longer need it since product now uses toolbar instead (May 3 at 11:58 AM)
520 12:00p 🔵 Screenshot functionality search returned no results in codebase
521 " 🔵 Existing text capture functionality found in native toolbar
522 " 🔵 Multi-mode display architecture discovered with multiple window types
523 12:01p 🔵 Comprehensive Extract learning point feature discovered across application layers
524 " 🔵 Native toolbar action routing and popup management system examined
525 12:02p 🔵 Complete AI processing pipeline and extract learning point architecture documented
526 " 🔵 TranslationWindow component architecture with extract learning point workflow
S191 Toolbar enable toggle and Panel Config implementation for popup action buttons (May 3 at 12:02 PM)
527 12:05p 🟣 Added toolbarEnabled setting to AppSettings
528 12:11p 🟣 Added toolbarEnabled setting infrastructure
529 " 🟣 Added settings imports to FeaturesPage for toolbar/panel config
530 " 🟣 Added settings state management to FeaturesPage
531 12:12p 🟣 Added toggleToolbarEnabled function for toolbar enable/disable
S192 Implement toolbar enable/disable toggle and Panel Config for popup action buttons (May 3 at 12:12 PM)
S193 Update PanelConfigPanel to work with combined toolbar items (May 3 at 12:13 PM)
S194 Verify Tauri build after PanelConfigPanel updates (May 3 at 12:13 PM)
S195 Update PanelConfigPanel to work with combined toolbar items (tools + AI features) (May 3 at 12:14 PM)
S196 Fixed two bugs: 1) Toolbar disable setting not being respected, 2) Panel Config items not matching popup button group (May 3 at 12:18 PM)
532 12:22p 🔴 Fixed toolbar disable functionality and panel config consistency
533 " 🔵 Root cause identified for toolbar disable bug
534 " 🔵 Native toolbar action system architecture documented
536 " ✅ Added ToolbarTool type import to TranslationWindow component
535 12:23p 🔵 TranslationWindow component structure and state management
537 12:24p ✅ Added tools state to TranslationWindow component
538 " ✅ Updated initializePopup to load and store toolbar tools
539 " 🔴 Fixed toolbar disable functionality in syncNativeToolbarActions
S197 Investigate and fix automatic toolbar re-enablement issue - trace the code path causing toolbar to be re-enabled after being disabled (May 3 at 12:24 PM)
540 12:57p 🔴 Toolbar disable config not respected during text selection
541 " 🔵 Clean Code skill definition loaded for toolbar bug investigation
542 " 🔵 Root cause identified: Selection monitor ignores global toolbar disable setting
543 12:58p 🔵 Architecture mapped for toolbar disable feature
544 " 🔵 Toolbar disable logic duplicated across two components
545 " 🔵 Tauri command bridge exposes three native toolbar functions to frontend
S198 修复工具栏禁用后自动重新开启的问题 (May 3 at 1:15 PM)
</claude-mem-context>