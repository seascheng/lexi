# Toolbar Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add built-in tools (Copy, Search, Read) to the native selection toolbar alongside existing AI features, with unified sort order management.

**Architecture:** Tools are lightweight toolbar items (no prompt, no popup) that execute immediately in Rust. They share the toolbar surface with AI features and are sorted by a unified `sortOrder`. Tool state is persisted as JSON in the settings table. The FeaturesPage gets a unified toolbar order preview at the top of the left panel.

**Tech Stack:** TypeScript/React (frontend), Rust (backend), Swift (native toolbar icons)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `src/types.ts` | Modify | Add `ToolbarToolId`, `ToolbarTool` types |
| `src/lib/defaults.ts` | Modify | Add `DEFAULT_TOOLS` and tool definitions |
| `src/lib/featureIcons.tsx` | Modify | Add `clipboard`, `search` icon mappings |
| `src/lib/database.ts` | Modify | Add `loadToolbarTools()`, `saveToolbarTools()` |
| `src/pages/FeaturesPage.tsx` | Modify | Add toolbar order section + tool detail panel |
| `src/components/translation/TranslationWindow.tsx` | Modify | Merge tools into `syncNativeToolbarActions()` |
| `src-tauri/src/native_toolbar.rs` | Modify | Add `copy`, `search` dispatch handlers |
| `src-tauri/native/SelectionToolbarHelper.swift` | Modify | Add `clipboard`, `search` SVG icon markup |

---

### Task 1: Add types and icon support

**Files:**
- Modify: `src/types.ts`
- Modify: `src/lib/featureIcons.tsx`
- Modify: `src/lib/defaults.ts`

- [ ] **Step 1: Add ToolbarTool types to `src/types.ts`**

Add after the existing `AiFeatureIcon` type line:

```typescript
export type ToolbarToolId = "copy" | "search" | "read";
```

Add after the `AiFeature` interface:

```typescript
export interface ToolbarTool {
  id: ToolbarToolId;
  name: string;
  description: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
}
```

- [ ] **Step 2: Add `clipboard` and `search` to `AiFeatureIcon` type in `src/types.ts`**

Change the `AiFeatureIcon` type to include the new icons:

```typescript
export type AiFeatureIcon = "languages" | "wand" | "pen" | "sparkles" | "book-plus" | "highlighter" | "file-text" | "message" | "clipboard" | "search";
```

- [ ] **Step 3: Add icon mappings in `src/lib/featureIcons.tsx`**

Add imports for the new Lucide icons:

```typescript
import { BookPlus, Clipboard, FileText, Highlighter, Languages, MessageSquare, PenLine, Search, Sparkles, Wand2 } from "lucide-react";
```

Add two new entries to `FEATURE_ICON_OPTIONS`:

```typescript
  { value: "clipboard", label: "Clipboard" },
  { value: "search", label: "Search" },
```

Add two new cases in the `FeatureIcon` function, before the default return:

```typescript
  if (icon === "clipboard") return <Clipboard size={size} />;
  if (icon === "search") return <Search size={size} />;
```

- [ ] **Step 4: Add `DEFAULT_TOOLS` in `src/lib/defaults.ts`**

Add import for the new type:

```typescript
import type { AiFeature, AppSettings, ToolbarTool } from "../types";
```

Add after `DEFAULT_SETTINGS`:

```typescript
export const TOOL_DESCRIPTIONS: Record<string, string> = {
  copy: "Copy selected text to clipboard.",
  search: "Search selected text in Google.",
  read: "Read selected text aloud.",
};

export const DEFAULT_TOOLS: ToolbarTool[] = [
  { id: "copy", name: "Copy", description: TOOL_DESCRIPTIONS.copy, icon: "clipboard", enabled: true, sortOrder: 100 },
  { id: "search", name: "Search", description: TOOL_DESCRIPTIONS.search, icon: "search", enabled: true, sortOrder: 110 },
  { id: "read", name: "Read", description: TOOL_DESCRIPTIONS.read, icon: "volume", enabled: true, sortOrder: 120 },
];
```

Note: Tools use high sortOrder (100+) by default so they sort after AI features (0, 10, 20...) by default.

- [ ] **Step 5: Verify frontend builds**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool && npx vite build 2>&1 | tail -5`
Expected: Build succeeds with no type errors.

- [ ] **Step 6: Commit**

```bash
git add src/types.ts src/lib/featureIcons.tsx src/lib/defaults.ts
git commit -m "feat: add ToolbarTool types, icons, and default definitions"
```

---

### Task 2: Add database functions for tool persistence

**Files:**
- Modify: `src/lib/database.ts`

- [ ] **Step 1: Add `loadToolbarTools()` function**

Add import for `DEFAULT_TOOLS`:

```typescript
import { DEFAULT_CUSTOM_PROMPT_TEMPLATE, DEFAULT_PROMPT_TEMPLATE, DEFAULT_REVIEW_FEATURE, DEFAULT_SETTINGS, DEFAULT_TOOLS, DEFAULT_TRANSLATION_FEATURE } from "./defaults";
```

Add import for `ToolbarTool`:

```typescript
import type { AiFeature, AiFeatureIcon, AiFeatureKind, AiOutputMode, AppSettings, LearningEntryInput, LearningEntryType, ReviewUpdate, ToolbarTool, WordEntry, WordStatus } from "../types";
```

Add constant:

```typescript
const TOOL_SETTINGS_KEY = "toolbar_tools";
```

Add function after `savePopupSize()`:

```typescript
export async function loadToolbarTools(): Promise<ToolbarTool[]> {
  if (!isTauriRuntime()) return loadBrowserToolbarTools();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ value: string }>>(
    "SELECT value FROM settings WHERE key = $1 LIMIT 1",
    [TOOL_SETTINGS_KEY],
  );

  if (!rows[0]?.value) return DEFAULT_TOOLS.map((tool) => ({ ...tool }));

  try {
    const saved = JSON.parse(rows[0].value) as Array<{ id: string; enabled: boolean; sortOrder: number }>;
    return DEFAULT_TOOLS.map((defaultTool) => {
      const override = saved.find((item) => item.id === defaultTool.id);
      return {
        ...defaultTool,
        enabled: override?.enabled ?? defaultTool.enabled,
        sortOrder: override?.sortOrder ?? defaultTool.sortOrder,
      };
    });
  } catch {
    return DEFAULT_TOOLS.map((tool) => ({ ...tool }));
  }
}

export async function saveToolbarTools(tools: ToolbarTool[]): Promise<void> {
  const data = tools.map((tool) => ({ id: tool.id, enabled: tool.enabled, sortOrder: tool.sortOrder }));

  if (!isTauriRuntime()) {
    localStorage.setItem("englist.toolbarTools", JSON.stringify(data));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)", [
    TOOL_SETTINGS_KEY,
    JSON.stringify(data),
  ]);
}
```

- [ ] **Step 2: Add browser fallback for tools**

Add after `loadBrowserPopupSize()`:

```typescript
function loadBrowserToolbarTools(): ToolbarTool[] {
  const saved = localStorage.getItem("englist.toolbarTools");
  if (!saved) return DEFAULT_TOOLS.map((tool) => ({ ...tool }));

  try {
    const overrides = JSON.parse(saved) as Array<{ id: string; enabled: boolean; sortOrder: number }>;
    return DEFAULT_TOOLS.map((defaultTool) => {
      const override = overrides.find((item) => item.id === defaultTool.id);
      return {
        ...defaultTool,
        enabled: override?.enabled ?? defaultTool.enabled,
        sortOrder: override?.sortOrder ?? defaultTool.sortOrder,
      };
    });
  } catch {
    return DEFAULT_TOOLS.map((tool) => ({ ...tool }));
  }
}
```

- [ ] **Step 3: Verify frontend builds**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool && npx vite build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/lib/database.ts
git commit -m "feat: add loadToolbarTools and saveToolbarTools database functions"
```

---

### Task 3: Update FeaturesPage with toolbar order and tool management

**Files:**
- Modify: `src/pages/FeaturesPage.tsx`

- [ ] **Step 1: Rewrite FeaturesPage with three left-panel sections**

Replace the entire content of `src/pages/FeaturesPage.tsx` with:

```typescript
import { emit } from "@tauri-apps/api/event";
import { ArrowDown, ArrowUp, Eye, EyeOff, Plus, Save, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { AiFeature, AiFeatureIcon, ToolbarTool } from "../types";
import { DEFAULT_CUSTOM_PROMPT_TEMPLATE, TOOL_DESCRIPTIONS } from "../lib/defaults";
import { deleteAiFeature, listAiFeatures, loadToolbarTools, saveAiFeature, saveToolbarTools } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { FEATURE_ICON_OPTIONS, FeatureIcon, isFeatureIcon } from "../lib/featureIcons";
import { isTauriRuntime } from "../lib/platform";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { Field, Input, Select, Textarea } from "../components/ui/Field";

type DraftItem =
  | { kind: "feature"; data: AiFeature }
  | { kind: "tool"; data: ToolbarTool };

export function FeaturesPage() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [tools, setTools] = useState<ToolbarTool[]>([]);
  const [draft, setDraft] = useState<DraftItem | null>(null);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  const activeFeature = useMemo(
    () => (draft?.kind === "feature" ? features.find((f) => f.id === draft.data.id) : undefined),
    [draft, features],
  );

  useEffect(() => {
    void refreshAll();
  }, []);

  async function refreshAll() {
    const [nextFeatures, nextTools] = await Promise.all([listAiFeatures(), loadToolbarTools()]);
    setFeatures(nextFeatures);
    setTools(nextTools);
    setDraft((currentDraft) => currentDraft ?? { kind: "feature", data: nextFeatures[0] } ?? null);
  }

  function refreshTools() {
    void loadToolbarTools().then(setTools);
  }

  // Unified toolbar items for the order preview
  const toolbarItems = useMemo(() => {
    const items: Array<{
      id: string;
      name: string;
      icon: AiFeatureIcon;
      enabled: boolean;
      sortOrder: number;
      kind: "tool" | "ai";
    }> = [
      ...tools.map((tool) => ({ id: tool.id, name: tool.name, icon: tool.icon, enabled: tool.enabled, sortOrder: tool.sortOrder, kind: "tool" as const })),
      ...features.filter((f) => f.enabled && f.kind !== "review").map((f) => ({ id: f.id, name: f.name, icon: f.icon, enabled: f.enabled, sortOrder: f.sortOrder, kind: "ai" as const })),
    ];
    return items.sort((a, b) => a.sortOrder - b.sortOrder);
  }, [tools, features]);

  function createFeature() {
    const sortOrder = features.reduce((max, feature) => Math.max(max, feature.sortOrder), 0) + 10;
    const feature: AiFeature = {
      id: `custom-${Date.now()}`,
      name: "New feature",
      kind: "custom",
      promptTemplate: DEFAULT_CUSTOM_PROMPT_TEMPLATE,
      outputMode: "plain_text",
      enabled: true,
      sortOrder,
      autoSaveToVocabulary: false,
      targetLanguage: "",
      reviewIntervalSeconds: 30,
      speechEnabled: false,
      icon: "wand",
    };
    setDraft({ kind: "feature", data: feature });
  }

  async function saveFeatureDraft() {
    if (draft?.kind !== "feature") return;
    const featureData = draft.data;

    setStatus("Saving...");
    setError("");
    try {
      await saveAiFeature(featureData);
      await refreshAll();
      await notifyFeaturesChanged();
      setStatus("Saved");
    } catch (saveError) {
      setError(errorMessage(saveError, "Feature was not saved."));
      setStatus("");
    }
  }

  async function removeFeature(feature: AiFeature) {
    if (feature.kind !== "custom") return;

    setStatus("Deleting...");
    setError("");
    try {
      await deleteAiFeature(feature.id);
      const nextFeatures = features.filter((item) => item.id !== feature.id);
      setFeatures(nextFeatures);
      setDraft(nextFeatures.length > 0 ? { kind: "feature", data: nextFeatures[0] } : null);
      await notifyFeaturesChanged();
      setStatus("Deleted");
    } catch (deleteError) {
      setError(errorMessage(deleteError, "Feature was not deleted."));
      setStatus("");
    }
  }

  function updateFeatureDraft(update: Partial<AiFeature>) {
    setDraft((current) =>
      current?.kind === "feature" ? { ...current, data: { ...current.data, ...update } } : current,
    );
    setStatus("");
  }

  async function toggleToolEnabled(toolId: string) {
    const nextTools = tools.map((tool) =>
      tool.id === toolId ? { ...tool, enabled: !tool.enabled } : tool,
    );
    setTools(nextTools);
    await saveToolbarTools(nextTools);
    await notifyFeaturesChanged();
    // Keep draft in sync if this tool was selected
    setDraft((current) => {
      if (current?.kind === "tool" && current.data.id === toolId) {
        return { ...current, data: { ...current.data, enabled: !current.data.enabled } };
      }
      return current;
    });
  }

  async function moveTool(toolId: string, direction: "up" | "down") {
    const idx = tools.findIndex((t) => t.id === toolId);
    if (idx < 0) return;
    if (direction === "up" && idx === 0) return;
    if (direction === "down" && idx === tools.length - 1) return;

    const nextTools = [...tools];
    const swapIdx = direction === "up" ? idx - 1 : idx + 1;
    const tmpOrder = nextTools[idx].sortOrder;
    nextTools[idx] = { ...nextTools[idx], sortOrder: nextTools[swapIdx].sortOrder };
    nextTools[swapIdx] = { ...nextTools[swapIdx], sortOrder: tmpOrder };

    setTools(nextTools.sort((a, b) => a.sortOrder - b.sortOrder));
    await saveToolbarTools(nextTools);
    await notifyFeaturesChanged();
  }

  async function updateToolSortOrder(toolId: string, sortOrder: number) {
    const nextTools = tools.map((tool) =>
      tool.id === toolId ? { ...tool, sortOrder } : tool,
    );
    setTools(nextTools);
    await saveToolbarTools(nextTools);
    await notifyFeaturesChanged();
    setDraft((current) => {
      if (current?.kind === "tool" && current.data.id === toolId) {
        return { ...current, data: { ...current.data, sortOrder } };
      }
      return current;
    });
  }

  const selectedDraftId =
    draft?.kind === "feature" ? draft.data.id : draft?.kind === "tool" ? draft.data.id : null;

  return (
    <div className="grid h-full min-h-0 gap-3 overflow-hidden lg:grid-cols-[260px_1fr]">
      <Card className="grid h-full min-h-0 content-start gap-2.5 overflow-y-auto">
        {/* Toolbar Order Section */}
        <div>
          <h2 className="text-lg font-semibold">Toolbar</h2>
          <p className="text-sm text-muted">{toolbarItems.filter((item) => item.enabled).length} items shown</p>
        </div>

        <div className="grid gap-1.5">
          {toolbarItems.map((item) => (
            <button
              className={`flex items-center gap-2 rounded-md border px-2.5 py-2 text-left transition ${
                selectedDraftId === item.id ? "border-accent bg-accent/10" : "border-border bg-surface hover:bg-surfaceHover"
              }`}
              key={item.id}
              onClick={() => {
                if (item.kind === "tool") {
                  const tool = tools.find((t) => t.id === item.id);
                  if (tool) setDraft({ kind: "tool", data: tool });
                } else {
                  const feature = features.find((f) => f.id === item.id);
                  if (feature) setDraft({ kind: "feature", data: feature });
                }
              }}
              type="button"
            >
              <FeatureIcon icon={item.icon} size={15} />
              <span className="min-w-0 flex-1 truncate text-sm font-medium text-strong">{item.name}</span>
              <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${item.kind === "tool" ? "bg-accent/15 text-accent" : "bg-surface text-muted"}`}>
                {item.kind === "tool" ? "Tool" : "AI"}
              </span>
              {!item.enabled ? <span className="text-[10px] text-muted">off</span> : null}
            </button>
          ))}
        </div>

        <div className="my-1 border-t border-border" />

        {/* AI Features Section */}
        <div className="flex items-center justify-between gap-2.5">
          <h3 className="text-sm font-semibold text-muted">AI Features</h3>
          <Button aria-label="New feature" onClick={createFeature} icon={<Plus size={16} />} />
        </div>

        <div className="grid gap-1.5">
          {features.map((feature) => (
            <button
              className={`rounded-md border px-2.5 py-2 text-left transition ${
                draft?.kind === "feature" && draft.data.id === feature.id ? "border-accent bg-accent/10" : "border-border bg-surface hover:bg-surfaceHover"
              }`}
              key={feature.id}
              onClick={() => setDraft({ kind: "feature", data: feature })}
              type="button"
            >
              <span className="flex min-w-0 items-center gap-2 text-sm font-medium text-strong">
                <FeatureIcon icon={feature.icon} size={15} />
                <span className="truncate">{feature.name}</span>
              </span>
              <span className="mt-1 block text-xs text-muted">
                {featureLabel(feature)}
                {feature.enabled ? "" : " / disabled"}
              </span>
            </button>
          ))}
        </div>

        <div className="my-1 border-t border-border" />

        {/* Tools Section */}
        <h3 className="text-sm font-semibold text-muted">Tools</h3>

        <div className="grid gap-1.5">
          {tools.sort((a, b) => a.sortOrder - b.sortOrder).map((tool) => (
            <button
              className={`flex items-center gap-2 rounded-md border px-2.5 py-2 text-left transition ${
                draft?.kind === "tool" && draft.data.id === tool.id ? "border-accent bg-accent/10" : "border-border bg-surface hover:bg-surfaceHover"
              }`}
              key={tool.id}
              onClick={() => setDraft({ kind: "tool", data: tool })}
              type="button"
            >
              <FeatureIcon icon={tool.icon} size={15} />
              <span className="min-w-0 flex-1 truncate text-sm font-medium text-strong">{tool.name}</span>
              {!tool.enabled ? <span className="text-[10px] text-muted">off</span> : null}
            </button>
          ))}
        </div>
      </Card>

      {/* Right Panel */}
      <Card className="grid h-full min-h-0 content-start gap-3 overflow-y-auto">
        {draft ? (
          draft.kind === "tool" ? (
            <ToolDetail
              tool={draft.data}
              tools={tools}
              onToggleEnabled={() => void toggleToolEnabled(draft.data.id)}
              onSortOrderChange={(value) => void updateToolSortOrder(draft.data.id, value)}
              onMoveUp={tools.findIndex((t) => t.id === draft.data.id) > 0 ? () => void moveTool(draft.data.id, "up") : undefined}
              onMoveDown={tools.findIndex((t) => t.id === draft.data.id) < tools.length - 1 ? () => void moveTool(draft.data.id, "down") : undefined}
            />
          ) : (
            <FeatureDetail
              draft={draft.data}
              activeFeature={activeFeature}
              status={status}
              error={error}
              onUpdate={updateFeatureDraft}
              onSave={() => void saveFeatureDraft()}
              onRemove={() => void removeFeature(draft.data)}
            />
          )
        ) : (
          <div className="rounded-md border border-border bg-surface px-4 py-3 text-sm text-muted">
            Select a feature or tool to view details.
          </div>
        )}
      </Card>
    </div>
  );
}

function ToolDetail({
  tool,
  tools,
  onToggleEnabled,
  onSortOrderChange,
  onMoveUp,
  onMoveDown,
}: {
  tool: ToolbarTool;
  tools: ToolbarTool[];
  onToggleEnabled: () => void;
  onSortOrderChange: (value: number) => void;
  onMoveUp?: () => void;
  onMoveDown?: () => void;
}) {
  return (
    <>
      <div className="flex flex-col gap-2.5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-lg font-semibold">{tool.name}</h2>
          <p className="text-sm text-muted">{TOOL_DESCRIPTIONS[tool.id] ?? "Built-in tool."}</p>
        </div>
        <Button
          onClick={onToggleEnabled}
          icon={tool.enabled ? <EyeOff size={16} /> : <Eye size={16} />}
          variant={tool.enabled ? "secondary" : "primary"}
        >
          {tool.enabled ? "Disable" : "Enable"}
        </Button>
      </div>

      <div className="grid gap-2.5 md:grid-cols-2">
        <Field label="Name">
          <Input disabled value={tool.name} />
        </Field>
        <Field label="Sort order">
          <div className="flex items-center gap-1.5">
            <Input
              onChange={(event) => onSortOrderChange(Number(event.target.value))}
              type="number"
              value={tool.sortOrder}
            />
            <Button onClick={onMoveUp} disabled={!onMoveUp} variant="ghost" icon={<ArrowUp size={16} />} />
            <Button onClick={onMoveDown} disabled={!onMoveDown} variant="ghost" icon={<ArrowDown size={16} />} />
          </div>
        </Field>
      </div>

      <div className="rounded-md border border-border bg-surface px-3 py-2">
        <p className="text-sm font-medium text-strong">Behavior</p>
        <p className="mt-1 text-xs leading-5 text-muted">
          {tool.id === "copy" && "Copies the selected text to clipboard. No popup window."}
          {tool.id === "search" && "Opens Google search with the selected text. No popup window."}
          {tool.id === "read" && "Reads the selected text aloud using system TTS. No popup window."}
        </p>
      </div>
    </>
  );
}

function FeatureDetail({
  draft,
  activeFeature,
  status,
  error,
  onUpdate,
  onSave,
  onRemove,
}: {
  draft: AiFeature;
  activeFeature: AiFeature | undefined;
  status: string;
  error: string;
  onUpdate: (update: Partial<AiFeature>) => void;
  onSave: () => void;
  onRemove: () => void;
}) {
  return (
    <>
      <div className="flex flex-col gap-2.5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-lg font-semibold">{activeFeature ? "Edit feature" : "New feature"}</h2>
          <p className="text-sm text-muted">
            {draft.kind === "translation"
              ? "Built-in translation feature for selected text."
              : draft.kind === "review"
                ? "Built-in vocabulary display for daily memory."
                : "Plain text AI result shown in the popup workspace."}
          </p>
        </div>
        <div className="flex gap-2">
          <Button
            onClick={() => onUpdate({ enabled: !draft.enabled })}
            icon={draft.enabled ? <EyeOff size={16} /> : <Eye size={16} />}
            variant={draft.enabled ? "secondary" : "primary"}
          >
            {draft.enabled ? "Disable" : "Enable"}
          </Button>
          {draft.kind === "custom" ? (
            <Button onClick={onRemove} variant="danger" icon={<Trash2 size={16} />}>
              Delete
            </Button>
          ) : null}
          <Button onClick={onSave} variant="primary" icon={<Save size={16} />}>
            Save
          </Button>
        </div>
      </div>

      <div className="grid gap-2.5 md:grid-cols-2">
        <Field label="Name">
          <Input
            disabled={draft.kind !== "custom"}
            onChange={(event) => onUpdate({ name: event.target.value })}
            value={draft.name}
          />
        </Field>
        <Field label="Tab order">
          <Input
            onChange={(event) => onUpdate({ sortOrder: Number(event.target.value) })}
            type="number"
            value={draft.sortOrder}
          />
        </Field>
        <Field label="Icon" hint="Shown on the popup action button.">
          <Select
            onChange={(event) => onUpdate({ icon: selectedFeatureIcon(event.target.value) })}
            value={draft.icon}
          >
            {FEATURE_ICON_OPTIONS.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Select>
        </Field>
        {draft.kind === "translation" ? (
          <Field label="Target language">
            <Input
              onChange={(event) => onUpdate({ targetLanguage: event.target.value })}
              value={draft.targetLanguage}
            />
          </Field>
        ) : null}
        {draft.kind === "review" ? (
          <Field label="Display interval" hint="Seconds between vocabulary cards in the popup.">
            <Input
              min={5}
              onChange={(event) => onUpdate({ reviewIntervalSeconds: Number(event.target.value) })}
              type="number"
              value={draft.reviewIntervalSeconds}
            />
          </Field>
        ) : null}
      </div>

      <label className="flex items-center gap-3 text-sm text-strong">
        <input
          checked={draft.speechEnabled}
          className="h-4 w-4 accent-[rgb(var(--color-accent))]"
          onChange={(event) => onUpdate({ speechEnabled: event.target.checked })}
          type="checkbox"
        />
        Show speech button in the popup
      </label>

      {draft.kind === "translation" ? (
        <label className="flex items-center gap-3 text-sm text-strong">
          <input
            checked={draft.autoSaveToVocabulary}
            className="h-4 w-4 accent-[rgb(var(--color-accent))]"
            onChange={(event) => onUpdate({ autoSaveToVocabulary: event.target.checked })}
            type="checkbox"
          />
          Auto-save translations to vocabulary
        </label>
      ) : null}

      {draft.kind !== "review" ? (
        <div className="rounded-md border border-border bg-surface px-3 py-2">
          <p className="text-sm font-medium text-strong">Popup actions</p>
          <p className="mt-1 text-xs leading-5 text-muted">
            This feature appears as an icon action next to the popup input. Extract is available as a learning-point action beside it.
          </p>
        </div>
      ) : null}

      {draft.kind !== "review" ? (
        <Field label="Prompt" hint="Use {{text}} for selected/input text. Translation also supports {{targetLanguage}}.">
          <Textarea
            className="min-h-64 font-mono"
            onChange={(event) => onUpdate({ promptTemplate: event.target.value })}
            value={draft.promptTemplate}
          />
        </Field>
      ) : null}

      <div className="rounded-md border border-border bg-example px-3 py-2 text-xs leading-5 text-muted">
        Output: {draft.kind === "review" ? "vocabulary cards" : draft.outputMode === "translation_json" ? "structured translation JSON" : "plain text"}.
        {status ? ` ${status}.` : ""}
      </div>
      {error ? (
        <div className="rounded-md border border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger">
          {error}
        </div>
      ) : null}
    </>
  );
}

async function notifyFeaturesChanged() {
  if (isTauriRuntime()) {
    await emit("englist://features-changed");
  }
}

function featureLabel(feature: AiFeature) {
  if (feature.kind === "translation") return "Translation";
  if (feature.kind === "review") return "Vocabulary display";
  return "Custom prompt";
}

function selectedFeatureIcon(value: string): AiFeatureIcon {
  return isFeatureIcon(value) ? value : "wand";
}
```

- [ ] **Step 2: Verify frontend builds**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool && npx vite build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/pages/FeaturesPage.tsx
git commit -m "feat: rewrite FeaturesPage with toolbar order, tools, and feature sections"
```

---

### Task 4: Merge tools into toolbar sync in TranslationWindow

**Files:**
- Modify: `src/components/translation/TranslationWindow.tsx`

- [ ] **Step 1: Update `syncNativeToolbarActions` to merge tools + features**

Find the existing `syncNativeToolbarActions` function (around line 341). Replace it with:

```typescript
  async function syncNativeToolbarActions(nextFeatures: AiFeature[]) {
    const enabledFeatures = nextFeatures.filter((feature) => feature.enabled && feature.kind !== "review");
    const nextTools = await loadToolbarTools();
    const enabledTools = nextTools.filter((tool) => tool.enabled);

    const items: Array<{ id: string; name: string; icon: AiFeatureIcon; sortOrder: number }> = [
      ...enabledTools.map((tool) => ({ id: tool.id, name: tool.name, icon: tool.icon, sortOrder: tool.sortOrder })),
      ...enabledFeatures.map((feature) => ({ id: feature.id, name: feature.name, icon: feature.icon, sortOrder: feature.sortOrder })),
    ];

    items.sort((a, b) => a.sortOrder - b.sortOrder);

    const actions: NativeToolbarAction[] = items.map((item) => ({
      id: item.id,
      title: item.name,
      icon: item.icon,
    }));

    actions.push({ id: "extract", title: "Extract", icon: "highlighter" });

    await invoke("set_native_toolbar_actions", { actions }).catch((error) => {
      console.warn("Failed to sync native toolbar actions", error);
    });
  }
```

Add the new import at the top of the file alongside existing database imports:

```typescript
import { loadToolbarTools } from "../../lib/database";
```

- [ ] **Step 2: Remove the old dynamic speak button logic**

The old code appended a `speak` button when `speechEnabled` was true for any feature. This is now handled by the `read` tool. Verify no other references to the old speak toolbar action exist.

- [ ] **Step 3: Verify frontend builds**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool && npx vite build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add src/components/translation/TranslationWindow.tsx
git commit -m "feat: merge tools and features in toolbar sync"
```

---

### Task 5: Add Rust dispatch handlers for copy and search

**Files:**
- Modify: `src-tauri/src/native_toolbar.rs`

- [ ] **Step 1: Add `copy_to_clipboard` and `open_search` functions**

Add these functions before the existing `dispatch_toolbar_action` function (around line 669):

```rust
fn copy_to_clipboard(text: String) -> Result<(), String> {
    // The clipboard manager plugin writes to the system clipboard
    // We use AppleScript as a simple cross-process clipboard write
    let output = std::process::Command::new("osascript")
        .arg("-e")
        .arg(format!("set the clipboard to {}", shell_escape(&text)))
        .output()
        .map_err(|e| format!("clipboard write failed: {e}"))?;

    if !output.status.success() {
        return Err("clipboard write failed".into());
    }
    Ok(())
}

fn open_search(text: String) -> Result<(), String> {
    let query = urlencoding::encode(&text);
    let url = format!("https://www.google.com/search?q={query}");
    open_url(&url)
}

fn open_url(url: &str) -> Result<(), String> {
    std::process::Command::new("open")
        .arg(url)
        .spawn()
        .map_err(|e| format!("failed to open URL: {e}"))?;
    Ok(())
}

fn shell_escape(s: &str) -> String {
    // Escape for AppleScript string literal (surround with quotes, escape inner quotes)
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}
```

- [ ] **Step 2: Update `dispatch_toolbar_action` match arms**

Replace the existing `dispatch_toolbar_action` match block with:

```rust
    match action.action.as_str() {
        "copy" => copy_to_clipboard(text),
        "search" => open_search(text),
        "read" | "speak" => speak_text(text),
        "translate" | "translation" => open_popup_with_feature(app, text, "translation"),
        "extract" => open_popup_with_extract(app, text),
        feature_id => open_popup_with_feature(app, text, feature_id),
    }
```

- [ ] **Step 3: Update `default_toolbar_actions` to match new tools**

Replace the `default_toolbar_actions` function with:

```rust
fn default_toolbar_actions() -> Vec<ToolbarActionItem> {
    vec![
        ToolbarActionItem {
            id: "translation".into(),
            title: "Translate".into(),
            icon: "languages".into(),
        },
        ToolbarActionItem {
            id: "copy".into(),
            title: "Copy".into(),
            icon: "clipboard".into(),
        },
        ToolbarActionItem {
            id: "search".into(),
            title: "Search".into(),
            icon: "search".into(),
        },
        ToolbarActionItem {
            id: "read".into(),
            title: "Read".into(),
            icon: "volume".into(),
        },
        ToolbarActionItem {
            id: "extract".into(),
            title: "Extract".into(),
            icon: "highlighter".into(),
        },
    ]
}
```

- [ ] **Step 4: Add `urlencoding` crate dependency**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool/src-tauri && cargo add urlencoding`

Or manually add to `Cargo.toml` under `[dependencies]`:

```toml
urlencoding = "2"
```

- [ ] **Step 5: Verify Rust compilation**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool/src-tauri && cargo check 2>&1 | tail -5`
Expected: Compiles with no errors.

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/native_toolbar.rs src-tauri/Cargo.toml src-tauri/Cargo.lock
git commit -m "feat: add copy and search toolbar action handlers in Rust"
```

---

### Task 6: Add Swift icon markup for clipboard and search

**Files:**
- Modify: `src-tauri/native/SelectionToolbarHelper.swift`

- [ ] **Step 1: Add new icon cases to `lucideMarkup`**

Find the `lucideMarkup` function (around line 39). Add these cases before the `default` case:

```swift
    case "clipboard":
        return """
        <rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M12 11h4"/><path d="M12 16h4"/><path d="M8 11h.01"/><path d="M8 16h.01"/>
        """
    case "search":
        return """
        <circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>
        """
```

- [ ] **Step 2: Verify the Swift file is syntactically valid**

The SVG markup is embedded in string literals — verify there are no unescaped quotes. The Lucide paths above use only `<>/"` characters inside triple-quoted strings, which is safe in Swift.

- [ ] **Step 3: Commit**

```bash
git add src-tauri/native/SelectionToolbarHelper.swift
git commit -m "feat: add clipboard and search SVG icons to native toolbar helper"
```

---

### Task 7: Full build verification

- [ ] **Step 1: Build frontend**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool && npx vite build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 2: Build Tauri app**

Run: `cd /Users/seascheng/Downloads/ai_project/englist-tool/src-tauri && cargo check 2>&1 | tail -5`
Expected: Compiles with no errors.

- [ ] **Step 3: Final commit (if any cleanup needed)**

Only if there are uncommitted fixes.
