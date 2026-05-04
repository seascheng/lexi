1. Please evaluate my proposal based on the current implementation and target requirements before executing it, rather than blindly following.
2. Fixing bugs must involve upward exploration, adopting a general solution from the root cause instead of workaround, cleaning up old code at last.
3. For implementing new feature, it is essential to ensure code reusability and follow the current file directory based on the existing architecture.
4. We pursue the separation of duties while avoiding excessive complexity and abstraction; we aim for clean code while avoiding fragmentation.

# Lexi

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

# [lexi] recent context, 2026-05-04 12:24pm GMT+8

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (16,481t read) | 0t work

### May 3, 2026
685 9:31p 🟣 Settings UI redesign for minimal layout
689 9:43p ✅ Removed grid gap spacing in ConfigsPage layout
690 9:47p ✅ Config page layout refined with narrower sidebar and spacing
691 9:51p 🔴 SettingsPage layout alignment issues with theme buttons and field positioning
692 9:52p 🔴 Fixed SettingsPage layout alignment issues with theme buttons and field positioning
693 9:59p 🔄 Changed Review page icon from Languages to Eye and reduced App sidebar width to 180px
694 10:06p 🔴 Clipboard corruption bug reported
695 " 🔵 Clipboard implementation files identified
696 10:07p 🔵 Clipboard code spans frontend and backend
697 " 🔵 Clipboard probe mechanism identified as corruption source
698 " 🔵 Clipboard architecture mapped across Rust and TypeScript layers
699 10:09p 🔵 Complete clipboard architecture mapped by explore agent
700 10:14p 🔵 DisplayMode setting controls AI translation window presentation behavior
701 10:25p 🔵 DisplayMode setting investigation completed - three presentation modes for AI translation results
702 10:26p 🔵 DisplayMode actively used in IPC event payloads and auto-hide logic, but UI shows non-functional options
703 " 🔵 DisplayMode parameter flows through Tauri IPC events between main window and popup window
704 " 🔵 Rust backend emits cycle-display-mode event at lib.rs line 127, completing full DisplayMode data flow
705 10:27p 🔵 System tray menu "Switch Mode" option provides second user access point for DisplayMode cycling
706 " ⚖️ Decision made to remove DisplayMode legacy code and replace with isBar-based auto-hide logic
707 " 🔄 Untitled
708 " 🔄 Untitled
709 " 🔄 Untitled
710 " 🔄 Untitled
S270 Markdown rendering not working for word details in VocabularyPage (May 3 at 10:42 PM)
711 10:45p 🔴 Markdown rendering not working in VocabularyPage
S271 Fix Mac application multi-desktop/multi-monitor popup positioning bug (May 3 at 10:46 PM)
712 10:51p 🔵 Mac popup window positioning issue identified
713 " 🔵 Popup window positioning uses cursor coordinates without desktop/monitor context
714 10:52p 🔵 Multi-desktop popup positioning requires NSScreen context awareness
716 " 🔵 Comprehensive popup architecture analysis reveals complete multi-monitor support gap
S272 Fix Mac application multi-desktop popup positioning - multi-Spaces support completed (May 3 at 10:52 PM)
715 10:53p 🔵 Swift toolbar helper implements correct multi-monitor screen detection
S273 Fix Mac application multi-desktop popup positioning - multi-Spaces support completed with thread-safe implementation (May 3 at 11:03 PM)
S274 Implemented configurable popup keyboard shortcut in settings (May 3 at 11:03 PM)
717 11:07p 🔵 Project structure analysis for global shortcut feature
718 " 🔵 Tauri app architecture analysis for global hotkey implementation
719 " 🔵 Frontend and backend codebase structure mapped
720 " 🔵 Existing global hotkey implementation found in native toolbar
721 " 🔵 Comprehensive popup lifecycle and hotkey architecture documented
722 11:08p 🟣 Added useCallback import to SettingsPage
723 11:16p 🟣 Implemented backend infrastructure for popup shortcut configuration
724 11:17p 🟣 Implemented ShortcutRecorder component for keyboard shortcut capture
725 " 🟣 Integrated popup shortcut sync with Tauri backend
726 11:18p 🔄 Refactored keycode enum references to explicit paths in key_name_to_code
727 " 🔴 Fixed keycode mapping for quote/apostrophe key in key_name_to_code
S275 Fixed popup keyboard shortcut not appearing when pressed without selected text (May 3 at 11:18 PM)
728 11:20p 🔴 Popup keyboard shortcut not triggering window display
729 " 🔴 Investigating popup shortcut failure - examining event tap callback
730 11:31p 🔴 Found event handler structure - examining KeyDown case
731 " 🔵 Found the bug - KeyDown handler only shows popup when text is selected
732 " 🔴 Fixing popup shortcut handler to show window without selected text
733 11:32p 🔴 Fixed popup shortcut to show window without selected text
734 " 🔴 Popup shortcut fix successfully applied and compiled
S278 User inquired whether rewriting popup in Swift+AppUI would improve performance compared to current Tauri implementation (May 3 at 11:33 PM)
736 11:34p 🟣 Optimized popup shortcut UX - shows popup immediately without delay
S276 Fixed and optimized popup keyboard shortcut that wasn't working when pressed (May 3 at 11:35 PM)
S277 User asked whether rewriting popup in Swift+AppUI would improve performance (May 3 at 11:35 PM)
### May 4, 2026
S279 User asked whether rewriting popup in Swift+AppUI would improve performance (May 4 at 10:09 AM)
738 10:20a 🔵 Project structure and technology stack identified
739 " 🔵 Codebase architecture and patterns analyzed for note feature implementation
</claude-mem-context>