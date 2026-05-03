# Panel System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an extensible panel system to the popup window with Translate and Review panels, pill-tab switching in the header, and a ConfigsPage with panel management.

**Architecture:** Panel registry maps string IDs to React components. `Panel` entities are persisted in SQLite/localStorage. `FloatingFrame` renders pill tabs from enabled panels. `TranslationWindow` uses the registry to render the active panel. Review moves from the features system into a panel.

**Tech Stack:** Tauri, React, TypeScript, SQLite (tauri-plugin-sql), Tailwind CSS

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/types.ts` | Add `Panel`, `PanelId` types; remove `"review"` from `AiFeatureKind`; add `activePanelId` to `AppSettings` |
| Modify | `src/lib/defaults.ts` | Add `DEFAULT_PANELS`; remove `DEFAULT_REVIEW_FEATURE` |
| Create | `src/lib/panelRegistry.ts` | Panel ID → component registry |
| Create | `src-tauri/migrations/007_panels.sql` | Create `panels` table |
| Modify | `src/lib/database.ts` | Add panel CRUD; remove review handling from features |
| Modify | `src/components/translation/FloatingFrame.tsx` | Add pill tabs to header |
| Modify | `src/components/translation/TranslationWindow.tsx` | Panel state, switching, toolbar reset |
| Create | `src/components/translation/ReviewPanel.tsx` | SM2 flashcard UI for popup |
| Rename+Modify | `src/pages/FeaturesPage.tsx` → `ConfigsPage.tsx` | Rename, add Panels section, remove review from features |
| Modify | `src/App.tsx` | Rename nav item, page type |
| Modify | `src/lib/nativeToolbar.ts` | Remove `kind !== "review"` filter |
| Modify | `src-tauri/src/lib.rs` | Register migration 007 |

---

### Task 1: Types and Defaults

**Files:**
- Modify: `src/types.ts`
- Modify: `src/lib/defaults.ts`

- [ ] **Step 1: Update types**

In `src/types.ts`:

Replace line 7:
```typescript
// Before:
export type AiFeatureKind = "translation" | "review" | "custom";
// After:
export type AiFeatureKind = "translation" | "custom";
```

Remove `reviewIntervalSeconds` from `AiFeature` interface (line 73 — the field `reviewIntervalSeconds: number`).

Add after `ToolbarTool` interface (after line 89):
```typescript
export type PanelId = string;

export interface Panel {
  id: PanelId;
  name: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
}
```

Add `activePanelId` to `AppSettings` (after line 49, before closing brace):
```typescript
activePanelId: string | null;
```

- [ ] **Step 2: Update defaults**

In `src/lib/defaults.ts`:

Remove the entire `DEFAULT_REVIEW_FEATURE` block (lines 38-53).

Add after `DEFAULT_TRANSLATION_FEATURE`:
```typescript
export const DEFAULT_PANELS: Panel[] = [
  { id: "translate", name: "Translate", icon: "languages", enabled: true, sortOrder: 0 },
  { id: "review", name: "Review", icon: "book-open", enabled: true, sortOrder: 1 },
];
```

Add `import type { Panel } from "../types";` to imports at top.

Remove `reviewIntervalSeconds: 30` from `DEFAULT_TRANSLATION_FEATURE` (line 34).

Add `activePanelId: null` to `DEFAULT_SETTINGS` (after `toolbarEnabled`).

- [ ] **Step 3: Commit**

```bash
git add src/types.ts src/lib/defaults.ts
git commit -m "feat: add Panel type, remove review from AiFeatureKind"
```

---

### Task 2: Panel Registry

**Files:**
- Create: `src/lib/panelRegistry.ts`

- [ ] **Step 1: Create registry**

Create `src/lib/panelRegistry.ts`:
```typescript
import type { ComponentType } from "react";
import type { WordEntry } from "../types";

export interface PanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

const registry = new Map<string, ComponentType<PanelProps>>();

export function registerPanel(id: string, component: ComponentType<PanelProps>): void {
  registry.set(id, component);
}

export function getPanelComponent(id: string): ComponentType<PanelProps> | undefined {
  return registry.get(id);
}
```

- [ ] **Step 2: Commit**

```bash
git add src/lib/panelRegistry.ts
git commit -m "feat: add panel registry for ID-to-component mapping"
```

---

### Task 3: Database Migration and Panel CRUD

**Files:**
- Create: `src-tauri/migrations/007_panels.sql`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src/lib/database.ts`

- [ ] **Step 1: Create migration**

Create `src-tauri/migrations/007_panels.sql`:
```sql
CREATE TABLE IF NOT EXISTS panels (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  icon TEXT NOT NULL DEFAULT 'wand',
  enabled INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0
);
```

- [ ] **Step 2: Register migration in lib.rs**

In `src-tauri/src/lib.rs`, add to the `migrations()` function (after migration 6):

```rust
Migration {
    version: 7,
    description: "create_panels_table",
    sql: include_str!("../migrations/007_panels.sql"),
    kind: MigrationKind::Up,
},
```

- [ ] **Step 3: Add panel CRUD to database.ts**

In `src/lib/database.ts`, add after the toolbar tools section (after line 149):

```typescript
// ── Panels ──────────────────────────────────────────────

export async function listPanels(): Promise<Panel[]> {
  if (!isTauriRuntime()) {
    const raw = localStorage.getItem("englist.panels");
    const rows: Panel[] = raw ? JSON.parse(raw) : [];
    return withBuiltInPanels(rows);
  }
  const db = await getDb();
  const rows = await db.select<PanelRow[]>("SELECT * FROM panels ORDER BY sort_order");
  return withBuiltInPanels(rows.map(panelFromRow));
}

export async function savePanel(panel: Panel): Promise<void> {
  if (!isTauriRuntime()) {
    const panels = await listPanels();
    const idx = panels.findIndex((p) => p.id === panel.id);
    if (idx >= 0) panels[idx] = panel;
    else panels.push(panel);
    localStorage.setItem("englist.panels", JSON.stringify(panels));
    return;
  }
  const db = await getDb();
  await db.execute(
    `INSERT INTO panels (id, name, icon, enabled, sort_order)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT(id) DO UPDATE SET name=$2, icon=$3, enabled=$4, sort_order=$5`,
    [panel.id, panel.name, panel.icon, panel.enabled ? 1 : 0, panel.sortOrder]
  );
}
```

Add the helper types and functions near the bottom of the file (near other helpers like `withBuiltInFeatures`):

```typescript
interface PanelRow {
  id: string;
  name: string;
  icon: string;
  enabled: number;
  sort_order: number;
}

function panelFromRow(row: PanelRow): Panel {
  return {
    id: row.id,
    name: row.name,
    icon: (row.icon as AiFeatureIcon) || "wand",
    enabled: row.enabled !== 0,
    sortOrder: row.sort_order ?? 0,
  };
}

function withBuiltInPanels(panels: Panel[]): Panel[] {
  for (const def of DEFAULT_PANELS) {
    if (!panels.some((p) => p.id === def.id)) {
      panels.push({ ...def });
    }
  }
  return panels.sort((a, b) => a.sortOrder - b.sortOrder);
}
```

Add `Panel` to the imports from `../types` at the top of database.ts, and add `DEFAULT_PANELS` to the imports from `./defaults`.

- [ ] **Step 4: Remove review handling from features**

In `src/lib/database.ts`:

In `normalizedAiFeature()` (around line 648), remove the `&& kind !== "review"` part:
```typescript
// Before:
panelEnabled: feature.panelEnabled !== false && feature.kind !== "review",
// After:
panelEnabled: feature.panelEnabled !== false,
```

In `withBuiltInFeatures()` (around lines 694-703), remove the review feature injection — only inject translation:
```typescript
function withBuiltInFeatures(features: AiFeature[]): AiFeature[] {
  if (!features.some((f) => f.id === DEFAULT_TRANSLATION_FEATURE.id)) {
    features.unshift({ ...DEFAULT_TRANSLATION_FEATURE });
  }
  return features.sort((a, b) => a.sortOrder - b.sortOrder);
}
```

In `isBuiltInFeatureId()` (around line 705-707), remove `"review"`:
```typescript
function isBuiltInFeatureId(id: string): boolean {
  return id === "translation";
}
```

In `aiFeatureFromRow()` (around line 584-601), remove `reviewIntervalSeconds` mapping (since the field no longer exists on `AiFeature`).

- [ ] **Step 5: Commit**

```bash
git add src-tauri/migrations/007_panels.sql src-tauri/src/lib.rs src/lib/database.ts
git commit -m "feat: add panels table migration and CRUD, remove review from feature system"
```

---

### Task 4: Remove Review Filters Everywhere

**Files:**
- Modify: `src/lib/nativeToolbar.ts`
- Modify: `src/components/translation/TranslationWindow.tsx`

- [ ] **Step 1: Fix nativeToolbar.ts**

In `src/lib/nativeToolbar.ts` line 32, remove the `kind !== "review"` filter:

```typescript
// Before:
const featureActions = features.filter((feature) => feature.enabled && feature.kind !== "review");
// After:
const featureActions = features.filter((feature) => feature.enabled);
```

- [ ] **Step 2: Fix TranslationWindow.tsx filters**

In `src/components/translation/TranslationWindow.tsx`:

Line 76 — `actionFeatures`:
```typescript
// Before:
const actionFeatures = useMemo(() => features.filter(f => f.panelEnabled && f.kind !== "review").sort(...), [features]);
// After:
const actionFeatures = useMemo(() => features.filter(f => f.panelEnabled).sort(...), [features]);
```

Line 85 — `panelItems` features filter:
```typescript
// Before:
features.filter(f => f.panelEnabled && f.kind !== "review")
// After:
features.filter(f => f.panelEnabled)
```

Line 428 — `currentActionFeature` filter:
```typescript
// Before:
featuresRef.current.filter((feature) => feature.enabled && feature.kind !== "review")
// After:
featuresRef.current.filter((feature) => feature.enabled)
```

- [ ] **Step 3: Commit**

```bash
git add src/lib/nativeToolbar.ts src/components/translation/TranslationWindow.tsx
git commit -m "refactor: remove review exclusion filters from toolbar and popup"
```

---

### Task 5: FloatingFrame Pill Tabs

**Files:**
- Modify: `src/components/translation/FloatingFrame.tsx`

- [ ] **Step 1: Add pill tabs to FloatingFrame**

Add new props to `FloatingFrame`:
```typescript
interface FloatingFrameProps {
  children: React.ReactNode;
  className?: string;
  isPinned: boolean;
  panels?: Panel[];
  activePanelId?: string;
  onPanelChange?: (id: string) => void;
  onClose: () => void;
  onTogglePin: () => void;
  onStartResize?: (info: PopupResizeStart) => void;
}
```

Add `import type { Panel } from "../../types";` to imports.

In the header area (between close button and pin button), add the pill tabs. The current structure has the close button at `left-2.5 top-2.5` (line 106-116) and pin button at `right-2.5 top-2.5` (lines 117-126). Add pill tabs centered between them:

```tsx
{/* Panel Tabs */}
{panels && panels.length > 1 && (
  <div className="absolute left-1/2 top-2 -translate-x-1/2 z-20 flex items-center gap-0.5 rounded-md bg-white/[0.06] p-0.5">
    {panels.map((panel) => (
      <button
        key={panel.id}
        onClick={() => onPanelChange?.(panel.id)}
        className={`rounded px-3 py-0.5 text-xs font-medium transition-colors ${
          activePanelId === panel.id
            ? "bg-white/[0.12] text-white"
            : "text-white/40 hover:text-white/60"
        }`}
      >
        {panel.name}
      </button>
    ))}
  </div>
)}
```

Place this after the close button div and before the drag region div. The drag region should remain as-is — the tabs float above it.

- [ ] **Step 2: Commit**

```bash
git add src/components/translation/FloatingFrame.tsx
git commit -m "feat: add pill tab switcher to FloatingFrame header"
```

---

### Task 6: ReviewPanel Component

**Files:**
- Create: `src/components/translation/ReviewPanel.tsx`

- [ ] **Step 1: Create ReviewPanel**

Create `src/components/translation/ReviewPanel.tsx` — adapted from `ReviewPage.tsx` with compact layout:

```tsx
import { useState, useMemo } from "react";
import type { WordEntry, ReviewRating } from "../../types";
import { dueWords, scheduleReview, applyReviewUpdate } from "../../lib/database";
import { Button } from "../ui/Button";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";
import { StatusBadge } from "../ui/StatusBadge";

interface ReviewPanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

export function ReviewPanel({ words, onWordsChanged }: ReviewPanelProps) {
  const [revealed, setRevealed] = useState(false);
  const [completed, setCompleted] = useState(0);
  const [currentIdx, setCurrentIdx] = useState(0);

  const due = useMemo(() => dueWords(words), [words]);

  const current = due[currentIdx];

  async function rateWord(rating: ReviewRating) {
    if (!current) return;
    const update = scheduleReview(current, rating);
    await applyReviewUpdate(current.id, update);
    setRevealed(false);
    setCompleted((c) => c + 1);
    setCurrentIdx((i) => i + 1);
    onWordsChanged();
  }

  // Complete state
  if (!current) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-8">
        <div className="text-2xl">✓</div>
        <p className="text-sm text-white/60">Review complete</p>
        {completed > 0 && (
          <p className="text-xs text-white/40">{completed} words reviewed</p>
        )}
        {due.length === 0 && completed === 0 && (
          <p className="text-xs text-white/40">No words due for review</p>
        )}
      </div>
    );
  }

  // Active card
  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Progress bar */}
      <div className="flex items-center gap-2 px-4 pt-3 pb-1">
        <span className="text-[10px] text-white/40">
          {currentIdx + 1}/{due.length}
        </span>
        <div className="h-1 flex-1 rounded-full bg-white/10">
          <div
            className="h-1 rounded-full bg-indigo-500/60 transition-all"
            style={{ width: `${((currentIdx + 1) / due.length) * 100}%` }}
          />
        </div>
      </div>

      {/* Card */}
      <div className="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-3">
        {/* Front */}
        <div className="flex flex-col items-center gap-1">
          <span className="text-[10px] uppercase tracking-wider text-white/30">Word</span>
          <p className="text-lg font-medium text-white">{current.word}</p>
          <StatusBadge status={current.status} />
        </div>

        {/* Reveal / Back */}
        {!revealed ? (
          <div className="flex justify-center pt-2">
            <Button variant="ghost" size="sm" onClick={() => setRevealed(true)}>
              Reveal
            </Button>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {current.translation && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-white/30">Translation</span>
                <p className="text-sm text-white/80">{current.translation}</p>
              </div>
            )}
            {current.definition && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-white/30">Definition</span>
                <MarkdownRenderer content={current.definition} />
              </div>
            )}
            {current.example && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-white/30">Example</span>
                <MarkdownRenderer content={current.example} />
              </div>
            )}

            {/* Rating buttons */}
            <div className="grid grid-cols-4 gap-2 pt-2">
              <Button variant="danger" size="sm" onClick={() => rateWord("again")}>Again</Button>
              <Button variant="secondary" size="sm" onClick={() => rateWord("hard")}>Hard</Button>
              <Button variant="primary" size="sm" onClick={() => rateWord("good")}>Good</Button>
              <Button variant="primary" size="sm" onClick={() => rateWord("easy")}>Easy</Button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
```

Note: `dueWords` and `scheduleReview` are imported from `database.ts`. `scheduleReview` currently lives in `src/lib/sm2.ts` — the import above should use `sm2.ts`:
```typescript
import { scheduleReview } from "../../lib/sm2";
```

And `applyReviewUpdate` from `database.ts`:
```typescript
import { dueWords, applyReviewUpdate } from "../../lib/database";
```

Wait — `dueWords` is in `database.ts` but `scheduleReview` is in `sm2.ts`. Fix imports:
```typescript
import { dueWords, applyReviewUpdate } from "../../lib/database";
import { scheduleReview } from "../../lib/sm2";
```

- [ ] **Step 2: Register ReviewPanel in panel registry**

This will be done in Task 7 (TranslationWindow integration). No separate commit needed here.

- [ ] **Step 3: Commit**

```bash
git add src/components/translation/ReviewPanel.tsx
git commit -m "feat: add ReviewPanel component with SM2 flashcard UI for popup"
```

---

### Task 7: TranslationWindow Panel Integration

**Files:**
- Modify: `src/components/translation/TranslationWindow.tsx`

- [ ] **Step 1: Add imports**

Add at top of `TranslationWindow.tsx`:
```typescript
import type { Panel } from "../../types";
import { listPanels, loadSettings, saveSettings, listWords } from "../../lib/database";
import { registerPanel, getPanelComponent } from "../../lib/panelRegistry";
import { ReviewPanel } from "./ReviewPanel";
```

- [ ] **Step 2: Register panels at module level**

After imports, before the component:
```typescript
registerPanel("review", ReviewPanel);
```

Note: "translate" panel is not registered because it renders the existing workspace inline (it's not a separate component — it's the current default content).

- [ ] **Step 3: Add state declarations**

After existing state declarations (after line ~64):
```typescript
const [panels, setPanels] = useState<Panel[]>([]);
const [activePanelId, setActivePanelId] = useState<string>("translate");
const [words, setWords] = useState<WordEntry[]>([]);
```

Add `import type { WordEntry } from "../../types";` if not already imported.

- [ ] **Step 4: Load panels and words in initializePopup**

In the `initializePopup` function (around line 329), add panel and word loading:
```typescript
const [loadedSettings, loadedFeatures, loadedTools, loadedPanels, loadedWords] = await Promise.all([
  loadSettings(),
  listAiFeatures(),
  loadToolbarTools(),
  listPanels(),
  listWords(),
]);
// ... existing settings/features/tools setters ...
setPanels(loadedPanels);
setWords(loadedWords);

// Restore active panel from settings
if (loadedSettings.activePanelId) {
  const enabledIds = loadedPanels.filter(p => p.enabled).map(p => p.id);
  if (enabledIds.includes(loadedSettings.activePanelId)) {
    setActivePanelId(loadedSettings.activePanelId);
  }
}
```

- [ ] **Step 5: Add panel change handler**

Add a handler function:
```typescript
function handlePanelChange(id: string) {
  setActivePanelId(id);
  // Persist to settings
  if (settings) {
    const updated = { ...settings, activePanelId: id };
    saveSettings(updated);
  }
}
```

- [ ] **Step 6: Add toolbar reset logic**

In the `englist://popup-shown` event handler (around line 173), add reset:
```typescript
// After existing resetPopupWorkspace logic:
// Reset to translate panel when opened from toolbar
setActivePanelId("translate");
```

- [ ] **Step 7: Listen for words-changed event**

Add event listener alongside existing ones:
```typescript
const unlistenWords = await listen("englist://words-changed", async () => {
  const refreshed = await listWords();
  setWords(refreshed);
});
// Add to cleanup
```

- [ ] **Step 8: Update render to support panels**

In the render section (around line 566), update the FloatingFrame to pass panel props:

```tsx
<FloatingFrame
  isPinned={isPinned}
  onClose={hidePopup}
  onStartResize={startWindowResize}
  onTogglePin={handleTogglePin}
  panels={panels.filter(p => p.enabled).sort((a, b) => a.sortOrder - b.sortOrder)}
  activePanelId={activePanelId}
  onPanelChange={handlePanelChange}
>
```

Update the content area to switch panels:

```tsx
{/* Inside FloatingFrame children */}
{activePanelId === "translate" ? (
  <WorkspacePage
    actionFeatures={actionFeatures}
    activeRun={activeRun}
    activeRunId={activeRunId}
    defaultFeature={defaultFeature}
    inputText={inputText}
    panelItems={panelItems}
    runs={runs}
    onDismissRun={dismissWorkspaceRun}
    onEntryTypeChange={updateRunEntryType}
    onClearRuns={clearWorkspaceRuns}
    onInputChange={setInputText}
    onRunFeatureInput={runFeatureFromInput}
    onSaveLearningEntry={saveLearningEntry}
    onToolAction={handleToolAction}
    onSelectRun={setActiveRunId}
    onSubmitDefault={submitDefaultFeature}
  />
) : (() => {
  const PanelComponent = getPanelComponent(activePanelId);
  return PanelComponent ? (
    <PanelComponent words={words} onWordsChanged={() => listWords().then(setWords)} />
  ) : null;
})()}
```

- [ ] **Step 9: Commit**

```bash
git add src/components/translation/TranslationWindow.tsx
git commit -m "feat: integrate panel switching into TranslationWindow"
```

---

### Task 8: ConfigsPage (Rename + Panels Section)

**Files:**
- Rename: `src/pages/FeaturesPage.tsx` → `src/pages/ConfigsPage.tsx`
- Modify: `src/pages/ConfigsPage.tsx`
- Modify: `src/App.tsx`

- [ ] **Step 1: Rename file and component**

```bash
git mv src/pages/FeaturesPage.tsx src/pages/ConfigsPage.tsx
```

In the renamed file:
- Rename `export function FeaturesPage` → `export function ConfigsPage`
- Update all `FeaturesPage` references within the file to `ConfigsPage`

- [ ] **Step 2: Remove review from FeaturesPage features sidebar**

In ConfigsPage, the features sidebar lists all features (line ~413). The review feature no longer exists as a feature, so it won't appear. No code change needed here — it's already handled by the removal of `DEFAULT_REVIEW_FEATURE`.

- [ ] **Step 3: Add Panels section to left sidebar**

In the left sidebar layout (around lines 370-461), add a "Panels" section under the Config section. Currently the Config section has "Toolbar" and "Panel" nav items. Add "Panels" as a third item:

Add to `DraftItem` type (around line 36):
```typescript
// Add to the union:
| { kind: "panels-config" }
```

Add a "Panels" nav item in the Config section of the sidebar:
```tsx
<button onClick={() => setDraft({ kind: "panels-config" })} className={...}>
  <Layers className="h-4 w-4" />
  <span>Panels</span>
</button>
```

Import `Layers` from lucide-react.

- [ ] **Step 4: Add PanelsConfigPanel**

Create a new panel component within ConfigsPage. When `draft.kind === "panels-config"`, render:

```tsx
function PanelsConfigPanel({ panels, onSave }: { panels: Panel[]; onSave: (panel: Panel) => void }) {
  return (
    <div className="space-y-6">
      <div>
        <h3 className="text-sm font-medium text-white">Popup Panels</h3>
        <p className="text-xs text-white/40">Configure which panels appear in the popup window</p>
      </div>
      <div className="space-y-2">
        {panels.map((panel) => (
          <div key={panel.id} className="flex items-center justify-between rounded-lg bg-white/[0.04] px-3 py-2">
            <div className="flex items-center gap-2">
              <FeatureIcon name={panel.icon} className="h-4 w-4 text-white/40" />
              <span className="text-sm text-white">{panel.name}</span>
            </div>
            <button
              onClick={() => onSave({ ...panel, enabled: !panel.enabled })}
              className={`h-5 w-9 rounded-full transition-colors ${panel.enabled ? "bg-indigo-600" : "bg-white/10"}`}
            >
              <div className={`h-4 w-4 rounded-full bg-white shadow transition-transform ${panel.enabled ? "translate-x-4" : "translate-x-0.5"}`} />
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
```

Add `panels` and `setPanels` state to ConfigsPage:
```typescript
const [panels, setPanels] = useState<Panel[]>([]);

// In the data loading useEffect:
const loadedPanels = await listPanels();
setPanels(loadedPanels);
```

Add `import type { Panel } from "../types";` and `import { listPanels, savePanel } from "../lib/database";`.

Add the save handler:
```typescript
async function savePanelDraft(panel: Panel) {
  await savePanel(panel);
  setPanels(await listPanels());
}
```

Add the panels-config case to the right panel rendering:
```tsx
{draft.kind === "panels-config" && (
  <PanelsConfigPanel panels={panels} onSave={savePanelDraft} />
)}
```

- [ ] **Step 5: Update App.tsx**

In `src/App.tsx`:

Update `Page` type (line 18):
```typescript
type Page = "vocabulary" | "review" | "configs" | "settings";
```

Update navItems (lines 20-25):
```typescript
const navItems = [
  { page: "vocabulary", label: "Expressions", icon: <BookOpen /> },
  { page: "review", label: "Review", icon: <Languages /> },
  { page: "configs", label: "Configs", icon: <Sparkles /> },
  { page: "settings", label: "Settings", icon: <Settings /> },
];
```

Update the import:
```typescript
// Before:
import { FeaturesPage } from "./pages/FeaturesPage";
// After:
import { ConfigsPage } from "./pages/ConfigsPage";
```

Update the render (find where FeaturesPage is rendered and replace):
```typescript
// Before:
page === "features" && <FeaturesPage ... />
// After:
page === "configs" && <ConfigsPage ... />
```

- [ ] **Step 6: Commit**

```bash
git add src/pages/ConfigsPage.tsx src/App.tsx
git commit -m "feat: rename FeaturesPage to ConfigsPage, add Panels config section"
```

---

### Task 9: Cleanup Review from FeaturesPage

**Files:**
- Modify: `src/pages/ConfigsPage.tsx`

- [ ] **Step 1: Remove review-specific UI from FeatureConfigPanel**

In ConfigsPage (formerly FeaturesPage), the `FeatureConfigPanel` has review-specific rendering:

- Lines 1048: Description text for review kind — remove the review branch
- Lines 1108-1122: `reviewIntervalSeconds` field — remove entirely
- Lines 1139-1150: Prompt textarea hidden for review — remove the review check, always show prompt textarea (since review is no longer a feature kind)

- [ ] **Step 2: Remove review filters in toolbar/panel config lists**

Remove `kind !== "review"` filters in ConfigsPage:
- Line ~94: `features.filter((f) => f.kind !== "review")` → `features.filter((f) => f)` or just `features`
- Line ~201: Same pattern

- [ ] **Step 3: Commit**

```bash
git add src/pages/ConfigsPage.tsx
git commit -m "refactor: remove review-specific code from ConfigsPage"
```

---

### Task 10: Build and Verify

**Files:**
- No new files

- [ ] **Step 1: Run TypeScript check**

```bash
cd /Users/seascheng/Downloads/ai_project/englist-tool && npx tsc --noEmit
```

Expected: No errors. Fix any type issues.

- [ ] **Step 2: Build the Tauri app**

```bash
cd /Users/seascheng/Downloads/ai_project/englist-tool/src-tauri && cargo build --release
```

Expected: Successful compilation.

- [ ] **Step 3: Build the full app bundle**

```bash
cd /Users/seascheng/Downloads/ai_project/englist-tool && npm run tauri build
```

Expected: Successful build with app bundle at `src-tauri/target/release/bundle/macos/Englist Tool.app`.

- [ ] **Step 4: Manual verification checklist**

- [ ] Main window sidebar shows "Configs" instead of "Features"
- [ ] ConfigsPage has a "Panels" section under Config
- [ ] Panels section shows Translate and Review with enable/disable toggles
- [ ] Popup header shows pill tabs (Translate | Review) when both enabled
- [ ] Clicking Review tab shows SM2 flashcard UI
- [ ] Clicking Translate tab shows original workspace
- [ ] Toolbar trigger resets to Translate panel
- [ ] Disabling a panel in Configs hides its tab in popup
- [ ] Review feature no longer appears in Features list
- [ ] No `kind !== "review"` filters remain in codebase

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: panel system complete — build and verify"
```
