# Panel System Design

Date: 2026-05-03

## Overview

Redesign the popup window to support multiple panels (views) with a tab switcher in the header. Introduce a `Panel` entity type, move the Review feature from the features system into a panel, and rename the "Features" navigation to "Configs".

## Decisions

- **Extensible panel system**: Initially Translate + Review, but designed to support future panels (e.g. memo, clipboard) without architecture changes
- **Full content replacement**: Switching panels completely swaps the popup content area
- **Pill tabs in header**: Minimal pill-style toggle between close and pin buttons
- **Panel config in ConfigsPage**: Users can enable/disable panels and reorder them
- **Toolbar trigger resets to Translate**: Opening popup from toolbar always shows Translate panel
- **Remember last panel on non-toolbar opens**: `activePanelId` persisted in settings
- **Same SM2 in popup**: Review panel uses the full SM2 flashcard flow, compact layout only

## Data Model

### New Types (`src/types.ts`)

```typescript
export type PanelId = string;  // extensible: "translate", "review", future: "memo", "clipboard", etc.

export interface Panel {
  id: PanelId;
  name: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
}
```

### Panel Registry (`src/lib/panelRegistry.ts`)

Maps panel IDs to their React components. Adding a new panel means: add default data + register component.

```typescript
import type { ComponentType } from "react";

// Each panel component receives its own props interface
export interface PanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

// Registry: panel ID → component
const registry = new Map<PanelId, ComponentType<PanelProps>>();

export function registerPanel(id: PanelId, component: ComponentType<PanelProps>): void;
export function getPanelComponent(id: PanelId): ComponentType<PanelProps> | undefined;
```

Registration happens at app startup:
```typescript
registerPanel("translate", TranslatePanel);
registerPanel("review", ReviewPanel);
```

### Modified Types

- `AiFeatureKind`: Remove `"review"`, keep `"translation" | "custom"`
- `AppSettings`: Add `activePanelId: PanelId | null`

### Defaults (`src/lib/defaults.ts`)

```typescript
export const DEFAULT_PANELS: Panel[] = [
  { id: "translate", name: "Translate", icon: "languages", enabled: true, sortOrder: 0 },
  { id: "review",    name: "Review",    icon: "book-open", enabled: true, sortOrder: 1 },
];
```

Remove `DEFAULT_REVIEW_FEATURE`.

### Storage (`src/lib/database.ts`)

- New functions: `listPanels()`, `savePanel(panel)`, `withBuiltInPanels()`
- SQLite: new `panels` migration (id TEXT PK, name, icon, enabled, sort_order)
- localStorage: key `"englist.panels"`
- `activePanelId` stored in `AppSettings` (existing settings table/localStorage)

## Popup Header (FloatingFrame)

### Layout

```
[✕ Close] ——— [Translate | Review] ——— [📌 Pin]
```

- Pill tabs centered between close and pin buttons
- Active tab: subtle background highlight (`rgba(255,255,255,0.12)`)
- Inactive tab: muted text (`#888`)
- When only 1 panel enabled → hide pill tabs entirely
- Drag region still works around tabs

### FloatingFrame Props

New props:
- `panels: Panel[]` — enabled panels, sorted by sortOrder
- `activePanelId: PanelId`
- `onPanelChange: (id: PanelId) => void`

## TranslationWindow

### State

- `panels: Panel[]` — loaded from database on mount, refreshed on `features-changed` event (or new `panels-changed` event)
- `activePanelId: PanelId` — initialized from `settings.activePanelId`, defaults to `"translate"`

### Panel Switching

```typescript
// Render via registry lookup — no if/else chain, extensible
const PanelComponent = getPanelComponent(activePanelId);
if (PanelComponent) {
  return <PanelComponent words={words} onWordsChanged={refreshWords} />;
}
```

### Toolbar Reset

- Listen to `englist://popup-shown` event
- If triggered from toolbar action → set `activePanelId` to `"translate"` and save to settings
- If triggered otherwise → restore `settings.activePanelId` (remember last panel)

### Data Loading

- Load `words` from database (via `listWords()`) for ReviewPanel
- Pass `words` + `refreshWords` callback to ReviewPanel
- Translate workspace data flow unchanged

## ReviewPanel Component

New file: `src/components/translation/ReviewPanel.tsx`

### Props

```typescript
interface ReviewPanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}
```

### Behavior

- Filter words via `dueWords(words)` — same as ReviewPage
- Show front side (word only) with "Reveal" button
- After reveal: show translation, definition, example
- Four rating buttons: Again / Hard / Good / Easy
- Call `scheduleReview()` from `src/lib/sm2.ts` on rating
- Progress bar at top (compact): position / total due
- Empty state: "No words due for review" with reassuring message

### Layout Differences from ReviewPage

- No search/filter/pagination controls
- More compact spacing for popup window
- Same card flow and SM2 logic

## ConfigsPage (renamed from FeaturesPage)

### Navigation Rename

- Sidebar item: "Features" → "Configs"
- `App.tsx` page type: `"features"` → `"configs"`
- File rename: `FeaturesPage.tsx` → `ConfigsPage.tsx`

### Sidebar Sections

```
Config
  ├─ Toolbar        (existing toolbar config)
  ├─ Panel          (existing popup action bar config)
  └─ Panels         ← NEW: panel management
Tools
  ├─ Copy
  ├─ Search
  └─ Read
Features
  ├─ Translation (built-in)
  └─ Custom features...
```

### New PanelsConfigPanel

- List all registered panels with enable/disable toggle
- Drag-and-drop reorder (controls tab order in popup header)
- Small preview of each panel

## Cleanup

### Remove from Features System

- Remove `"review"` from `AiFeatureKind` union type
- Remove `DEFAULT_REVIEW_FEATURE` from defaults
- Remove `withBuiltInFeatures()` review handling
- Remove all `kind !== "review"` filters throughout codebase:
  - `nativeToolbar.ts`
  - `TranslationWindow.tsx`
  - `FeaturesPage.tsx` (now ConfigsPage)
- Review is no longer a feature; it's a panel

### ReviewPage in Main Window

- `ReviewPage.tsx` stays unchanged in main window navigation
- Main window still has Vocabulary | Review | Configs | Settings sidebar
- The `reviewIntervalSeconds` field on `AiFeature` is removed (was only used by review feature)

## Files Changed

| File | Change |
|------|--------|
| `src/types.ts` | Add `Panel`, `PanelId` (string); modify `AiFeatureKind`, `AppSettings` |
| `src/lib/defaults.ts` | Add `DEFAULT_PANELS`; remove `DEFAULT_REVIEW_FEATURE` |
| `src/lib/panelRegistry.ts` | **New** — panel ID → component registry |
| `src/lib/database.ts` | Add panel CRUD functions; new migration for `panels` table |
| `src/components/translation/FloatingFrame.tsx` | Add pill tabs to header |
| `src/components/translation/TranslationWindow.tsx` | Panel state, switching logic, toolbar reset |
| `src/components/translation/ReviewPanel.tsx` | **New** — SM2 flashcard UI for popup |
| `src/pages/FeaturesPage.tsx` → `ConfigsPage.tsx` | Rename, add Panels section, remove review from features |
| `src/App.tsx` | Rename nav item, page type |
| `src/lib/nativeToolbar.ts` | Remove `kind !== "review"` filter |
| `src/lib/featureIcons.tsx` | No change (reuse icons) |
| `src-tauri/migrations/` | New migration for `panels` table |
