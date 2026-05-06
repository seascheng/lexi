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

# [lexi] recent context, 2026-05-06 11:49am GMT+8

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 50 obs (16,526t read) | 0t work

### May 5, 2026
1148 9:02p 🟣 Switched Volcengine TTS from WebSocket protocol to HTTP REST API
1149 " 🔄 Removed tokio-tungstenite and futures-util from Cargo.toml, added base64 dependency
1150 9:03p 🔴 Re-added futures-util dependency after discovering ai.rs still uses it
1151 " 🟣 Successfully compiled HTTP-based Volcengine TTS implementation
1152 " 🔄 Removed unused speak_text function from native_toolbar.rs
1153 9:06p 🔴 Volcengine TTS integration produces no logs during testing
1154 " 🔴 Toolbar theme inconsistency with global configuration
1155 9:31p 🔴 Toolbar fails to appear when running release binary with output redirection
1156 9:42p 🔵 Helper app LexiSelectionHelper.app missing from all expected locations
1157 " 🔵 Helper app LexiSelectionHelper.app found in both expected locations
1158 " 🔵 Helper app directory exists but appears empty or incomplete
1159 " 🔵 LexiSelectionHelper.app is a directory but lacks macOS .app bundle structure
1160 " 🔵 Helper app executable missing from Contents/MacOS/ directory
1161 " 🔵 Helper app bundle is complete with executable and signature
1162 9:43p 🔵 Native toolbar uses dedicated log file at LOG_PATH for helper app debugging
1163 " ✅ Added comprehensive logging to launch_helper function for toolbar diagnostics
1164 " ✅ Added comprehensive diagnostic logging to helper app launch sequence
1165 9:45p 🔵 Helper app not running - TCP connection refused preventing toolbar display
1166 " 🔵 Launch_helper logging not appearing despite setup_native_toolbar executing
1167 9:46p 🔵 Newly built diagnostic code not active - application running old binary
1168 " ✅ Added wait_for_helper function to verify helper app startup before monitoring selections
1169 9:50p 🔵 Helper app launch fails from command line but works when opening app bundle normally
S541 Add fallback mechanism for helper app launch to support both app bundle and command-line execution contexts (May 5 at 9:50 PM)
1170 9:56p 🔴 Added fallback mechanism for helper app launch to handle command-line execution
1172 " 🔴 Completed full app bundle build with helper fallback mechanism and TTS diagnostic logging
S539 Add fallback mechanism for helper app launch to support both app bundle and command-line execution contexts (May 5 at 9:56 PM)
S540 Add fallback mechanism for helper app launch to support both app bundle and command-line execution contexts (May 5 at 9:56 PM)
S542 Add comprehensive diagnostic logging for toolbar TTS and fix helper app launch failures across different execution contexts (May 5 at 9:57 PM)
1174 9:59p 🔴 Built release binary with enhanced TTS streaming diagnostics
1171 " 🔴 Built release binary with helper app launch fallback mechanism
1173 10:03p 🔴 Enhanced TTS streaming diagnostics with chunk-level and line-level logging
S543 Fix toolbar helper app launch failures and add comprehensive diagnostic logging for toolbar TTS (May 5 at 10:05 PM)
1175 10:13p 🔵 Volcengine TTS API returns error code 55000000 - resource ID mismatched with speaker
1177 " 🔄 Simplified launch_helper to use direct binary execution only
1176 10:14p 🔴 Fixed Volcengine TTS resource ID mismatch error by changing X-Api-Resource-Id header
S544 Helper app launch issue - binary spawns but doesn't start HTTP server (May 5 at 11:00 PM)
### May 6, 2026
1178 12:15a 🔵 Helper binary launches successfully but fails to listen on toolbar TCP port
S545 Fixed toolbar-read event being handled in bar window causing system TTS to override downloaded MP3 audio (May 6 at 6:21 AM)
1179 9:42a 🔴 TTS generates audio successfully but plays system voice instead
1180 9:49a 🔵 TTS downloads MP3 successfully but plays system voice instead
S547 Identified architectural coupling issue in TTS system - proposed refactoring to decouple UI from execution logic (May 6 at 9:54 AM)
1181 9:57a 🔵 TTS architecture has tight UI-execution coupling causing race conditions
1182 " ⚖️ Entered plan mode for TTS architecture refactoring
S546 Discovered architectural coupling issue in TTS system - UI layer tightly coupled to execution logic causing race conditions (May 6 at 9:57 AM)
1183 10:00a 🔵 TTS architecture exploration for refactoring - examined command registration and data flow
1184 " 🔵 Explored TTS data flow and tool configuration storage for refactoring design
1185 10:01a 🔵 Examined native toolbar synchronization mechanism for TTS refactoring planning
1186 10:02a 🔵 Comprehensive architecture mapping of read/speak feature completed by explore agent
1187 " 🔵 Architecture analysis identified two execution paths for TTS with root cause in event delegation pattern
1188 11:26a 🟣 Added visual separation to popup modals with borders and shadows
S548 Add visual separation (border or shadow) to popup modals for light and dark modes (May 6 at 11:27 AM)
1189 11:27a 🟣 Added border and shadow styling to popup components for visual isolation
1190 11:28a 🔵 Explored popup component architecture for border and shadow styling implementation
1191 " 🟣 Added border and shadow styling to FloatingFrame popup component
1192 " 🟣 Implemented popup visual isolation with theme-aware borders and shadows
1193 " 🟣 Built application with popup visual isolation styling
1195 " 🔵 Discovered three regressions after popup shadow implementation
1196 " 🔵 Investigating three regressions: shadow artifacts, keyboard shortcuts, and toolbar failures
1194 11:30a 🟣 Successfully built application with popup visual isolation feature
1197 11:46a 🔵 Root cause identified: Native toolbar helper app launch failure
</claude-mem-context>