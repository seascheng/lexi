# Toolbar Tools Design

## Problem

The native macOS selection toolbar currently only shows AI features (Translate, Review, custom prompts). Users want quick-access utility buttons — Copy, Search, Read — that act immediately without opening the popup window. These "tools" share the toolbar surface with AI features but are fundamentally different: no prompt, no popup, no AI call.

## Decision

Add a unified `ToolbarItem` model. Tools and features share the toolbar and are sorted together by `sortOrder`. The difference is only in what happens on click: tools execute immediately in Rust, features open the popup.

## Data Model

### New types (`types.ts`)

```typescript
type ToolbarToolId = "copy" | "search" | "read";

interface ToolbarTool {
  id: ToolbarToolId;
  name: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
}
```

### Built-in tools (`defaults.ts`)

| id | name | icon | behavior |
|---|---|---|---|
| `copy` | Copy | `clipboard` | Copy selected text to clipboard via Tauri clipboard plugin |
| `search` | Search | `search` | Open `https://www.google.com/search?q={text}` in default browser |
| `read` | Read | `volume` | Speak selected text via macOS `say` |

### Persistence

Tool state (enabled + sortOrder) is stored as a single JSON value in the `settings` table under key `toolbar_tools`. No database migration required.

```typescript
// Settings table row: key = "toolbar_tools", value = JSON
[
  { id: "copy", enabled: true, sortOrder: 5 },
  { id: "search", enabled: true, sortOrder: 15 },
  { id: "read", enabled: true, sortOrder: 25 }
]
```

Tools are defined in `defaults.ts` like `DEFAULT_TRANSLATION_FEATURE`. Users can only toggle `enabled` and change `sortOrder`. No create, no delete, no prompt editing.

## Toolbar Flow

### `syncNativeToolbarActions()` (TranslationWindow.tsx)

1. Load enabled tools from settings
2. Load enabled AI features (excluding review)
3. Merge into one list sorted by `sortOrder`
4. Append `extract` action (unchanged)
5. Send merged list to native toolbar via `invoke("set_native_toolbar_actions", { actions })`

### `dispatch_toolbar_action()` (native_toolbar.rs)

```rust
match action.as_str() {
    "copy" => copy_to_clipboard(text),
    "search" => open_search(text),
    "read" | "speak" => speak_text(text),
    "translate" | "translation" => open_popup_with_feature(app, text, "translation"),
    "extract" => open_popup_with_extract(app, text),
    feature_id => open_popup_with_feature(app, text, feature_id),
}
```

- `copy_to_clipboard` uses `tauri-plugin-clipboard-manager`
- `open_search` uses `tauri-plugin-opener` to open a URL in the default browser
- The existing `speak` action merges with the new `read` tool — one button, same behavior
- The feature-level `speechEnabled` flag still controls the popup workspace's internal speech button (separate concern)

### Speak button removal from dynamic toolbar

Currently `syncNativeToolbarActions()` appends a `speak` button when any feature has `speechEnabled=true`. This is replaced by the `read` tool. If the user enables the Read tool, it appears in the toolbar. If disabled, no speech button in the toolbar. The popup workspace's speech button per feature remains unchanged.

## FeaturesPage UI

### Left panel — three sections

**1. Toolbar Order (top)**

A unified preview list showing ALL toolbar items (tools + features) merged and sorted by `sortOrder`. This is the authoritative view of what appears on the native toolbar.

- Each row: icon + name + enable/disable toggle
- Rows tagged by type: "Tool" badge for tools, "AI" badge for features
- Up/down arrows to adjust sort order (updates the underlying tool/feature sortOrder)
- Clicking a row selects it and shows detail in the right panel
- Extract is always appended at the end (not shown in this list)

This lets the user see and arrange the exact toolbar layout in one place.

**2. AI Features (below)**

Current behavior — list of AI features with create button. Selecting a feature here also selects it in the right panel.

**3. Tools (below)**

Shows Copy, Search, Read. No create/delete. Selecting a tool shows its detail in the right panel.

### Right panel (tool selected)

When a tool is selected:

- Tool name (read-only)
- Icon (read-only)
- Description (read-only, e.g. "Copy selected text to clipboard")
- Enabled toggle
- Sort order input

No prompt editor, no output mode, no target language, no delete button.

### Right panel (feature selected)

Unchanged from current behavior.

### Sort order data flow

- Tool sort order changes → saved to `toolbar_tools` setting
- Feature sort order changes → saved to the feature's `ai_features` row
- The Toolbar Order list merges both sources on load, sorts by `sortOrder`

## Database Layer (`database.ts`)

New functions:

- `loadToolbarTools(): Promise<ToolbarTool[]>` — loads from settings key `toolbar_tools`, merges with defaults
- `saveToolbarTools(tools: ToolbarTool[]): Promise<void>` — saves to settings key `toolbar_tools`

Browser fallback uses localStorage under key `englist.toolbarTools`.

## File Changes Summary

| File | Change |
|---|---|
| `src/types.ts` | Add `ToolbarToolId`, `ToolbarTool` |
| `src/lib/defaults.ts` | Add `DEFAULT_TOOLS` array |
| `src/lib/database.ts` | Add `loadToolbarTools()`, `saveToolbarTools()` |
| `src/lib/featureIcons.tsx` | Add `clipboard`, `search` to icon options |
| `src/pages/FeaturesPage.tsx` | Add Tools section in left panel, tool detail in right panel |
| `src/components/translation/TranslationWindow.tsx` | Update `syncNativeToolbarActions()` to merge tools + features |
| `src-tauri/src/native_toolbar.rs` | Add `copy_to_clipboard()`, `open_search()` in `dispatch_toolbar_action()` |
