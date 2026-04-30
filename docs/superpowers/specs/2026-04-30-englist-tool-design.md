# Englist Tool — Design Spec

A Mac English learning app with global word selection translation, vocabulary management, and spaced repetition review.

## Tech Stack

- **Desktop Framework**: Tauri v2
- **Frontend**: Vite + React + TypeScript
- **UI Library**: shadcn/ui + Tailwind CSS
- **Database**: SQLite (via Tauri SQL plugin)
- **AI API**: OpenAI-compatible API (configurable base URL / key / model)

## Architecture

### Multi-Window Architecture

Three Tauri windows, each with a clear responsibility:

| Window | Purpose | Properties |
|--------|---------|------------|
| `main` | Vocabulary book, settings, review | Standard window, closable, re-openable via system tray |
| `float_bar` | Always-on / Auto-hide translation display | Frameless, always-on-top, top-center, transparent bg, rounded corners |
| `popup_card` | Popup card translation display | Frameless, always-on-top, appears near cursor, click-outside-to-close |

Inter-window communication via Tauri event system.

### System Integration

- **System Tray**: Click to show/hide main window, right-click menu (open main, switch display mode, quit)
- **Global Shortcut**: Default `Cmd+Shift+T` (configurable in settings)
- **Text Selection Capture**: macOS Accessibility API to get currently selected text

## Core Features

### 1. Global Word Selection Translation

**Flow**: User selects text in any app → presses shortcut → app captures selected text → sends to AI API → displays translation result in the configured display mode.

**AI API Configuration**:
- Base URL (e.g. `https://api.openai.com/v1`)
- API Key
- Model name (e.g. `gpt-4o-mini`)
- Custom prompt template (user-editable)
- Target language (default: Chinese)

**Language Detection**: AI auto-detects source language, translates to configured target language.

**Translation Result Contains**:
- Original word/phrase
- Translation (target language)
- Part of speech
- Brief definition (English)
- Example sentence
- Save-to-vocabulary button

### 2. Translation Display Modes (Configurable)

**Mode A — Always-on Bar**:
- `float_bar` window always visible at screen top, centered, ~70% width
- Shows translation result inline with save/close buttons
- Semi-transparent background, rounded corners

**Mode B — Auto-hide Bar**:
- `float_bar` window slides in from top when translation triggered
- Auto-hides after 5 seconds of inactivity
- Same layout as always-on bar

**Mode C — Popup Card**:
- `popup_card` window appears near cursor position
- Card-style layout with word, translation, definition, example sentence
- Save and Copy buttons
- Click outside or press Esc to close

### 3. Vocabulary Book (生词本)

**Auto-save**: Every translation result is automatically saved to vocabulary book. User can toggle auto-save in settings.

**Word Entry Fields**:
- `word` — original word/phrase
- `translation` — target language translation
- `pos` — part of speech
- `definition` — brief English definition
- `example` — example sentence
- `status` — New / Learning / Mastered
- `created_at` — date added
- `review_count` — number of reviews
- `next_review` — next scheduled review date
- `ease_factor` — SM-2 algorithm ease factor
- `interval` — SM-2 algorithm interval in days

**Management Features**:
- Search by word or translation
- Filter by status (All / New / Learning / Mastered)
- Delete individual entries
- Change status manually
- Bulk export (JSON/CSV)

### 4. Spaced Repetition Review

**Algorithm**: SM-2 (SuperMemo 2)

**Review Flow**:
1. Show word (front of card)
2. User thinks of the meaning
3. Reveal translation + definition (back of card)
4. User rates difficulty: Again / Hard / Good / Easy
5. SM-2 calculates next review date and ease factor
6. Next card

**Review Session**:
- Shows due words (where `next_review <= today`)
- Progress indicator (e.g. "5/12 due")
- Session summary when complete

### 5. Settings Page

**Sections**:

1. **Display Mode** — toggle between Always-on Bar / Auto-hide Bar / Popup Card
2. **Shortcut** — configure global shortcut key
3. **AI API** — base URL, API key, model, target language
4. **Translation Prompt** — editable prompt template
5. **Auto-save** — toggle auto-save translations to vocabulary
6. **About** — app version, links

## Data Model (SQLite)

### Tables

```sql
CREATE TABLE words (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  word TEXT NOT NULL,
  translation TEXT NOT NULL,
  pos TEXT,
  definition TEXT,
  example TEXT,
  status TEXT NOT NULL DEFAULT 'new',  -- new, learning, mastered
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  review_count INTEGER NOT NULL DEFAULT 0,
  next_review DATETIME,
  ease_factor REAL NOT NULL DEFAULT 2.5,
  interval INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

## Project Structure

```
englist-tool/
├── src-tauri/           # Tauri backend (Rust)
│   ├── src/
│   │   ├── main.rs      # App entry, window setup, tray
│   │   ├── commands/     # Tauri commands (IPC)
│   │   │   ├── translate.rs   # AI API call
│   │   │   ├── words.rs       # Vocabulary CRUD
│   │   │   ├── review.rs      # SM-2 review logic
│   │   │   └── settings.rs    # Settings read/write
│   │   ├── db.rs         # SQLite setup & migrations
│   │   └── selection.rs  # macOS text selection capture
│   ├── migrations/       # SQL migration files
│   └── Cargo.toml
├── src/                  # React frontend
│   ├── components/
│   │   ├── ui/           # shadcn/ui components
│   │   ├── vocabulary/   # Vocabulary book components
│   │   ├── review/       # Review flashcard components
│   │   ├── settings/     # Settings form components
│   │   └── translation/  # Translation display components
│   ├── pages/
│   │   ├── VocabularyPage.tsx
│   │   ├── ReviewPage.tsx
│   │   └── SettingsPage.tsx
│   ├── hooks/            # Custom React hooks
│   ├── lib/              # Utilities, Tauri IPC wrappers
│   ├── App.tsx
│   └── main.tsx
├── package.json
├── vite.config.ts
├── tailwind.config.ts
└── tsconfig.json
```

## Design Style

- **Theme**: Dark mode by default, with light mode support
- **Colors**: Dark background (#0a0a0f), subtle borders (#333), accent colors for status tags
- **Typography**: Clean sans-serif, clear hierarchy (word → translation → definition → example)
- **Spacing**: Generous padding, consistent 8px grid
- **Interactions**: Smooth transitions, no jarring animations
