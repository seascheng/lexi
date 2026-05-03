import { emit } from "@tauri-apps/api/event";
import { Eye, EyeOff, Plus, Save, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
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
  | { kind: "toolbar-config" }
  | { kind: "panel-config" }
  | { kind: "tool"; data: ToolbarTool }
  | { kind: "feature"; data: AiFeature };

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
    void refresh();
  }, []);

  async function refresh() {
    const [nextFeatures, nextTools] = await Promise.all([listAiFeatures(), loadToolbarTools()]);
    setFeatures(nextFeatures);
    setTools(nextTools);
    setDraft((current) => current ?? { kind: "toolbar-config" });
  }

  // --- Toolbar Config ---

  const allToolbarItems = useMemo(() => {
    const items: Array<{ id: string; name: string; icon: AiFeatureIcon; enabled: boolean; sortOrder: number; kind: "tool" | "ai" }> = [
      ...tools.map((t) => ({ id: t.id, name: t.name, icon: t.icon, enabled: t.enabled, sortOrder: t.sortOrder, kind: "tool" as const })),
      ...features.filter((f) => f.kind !== "review").map((f) => ({ id: f.id, name: f.name, icon: f.icon, enabled: f.enabled, sortOrder: f.sortOrder, kind: "ai" as const })),
    ];
    return items.sort((a, b) => a.sortOrder - b.sortOrder);
  }, [tools, features]);

  const enabledToolbarItems = allToolbarItems.filter((i) => i.enabled);

  async function toggleToolbarItem(item: { id: string; kind: "tool" | "ai" }) {
    if (item.kind === "tool") {
      const next = tools.map((t) => t.id === item.id ? { ...t, enabled: !t.enabled } : t);
      setTools(next);
      await saveToolbarTools(next);
    } else {
      const feature = features.find((f) => f.id === item.id);
      if (!feature) return;
      const updated = { ...feature, enabled: !feature.enabled };
      await saveAiFeature(updated);
      setFeatures((prev) => prev.map((f) => (f.id === updated.id ? updated : f)));
    }
    await notifyChanged();
  }

  // Drag state is managed inside ToolbarConfigPanel via pointer events

  async function applyReorder(from: number, to: number) {
    const sorted = [...allToolbarItems];
    const [moved] = sorted.splice(from, 1);
    sorted.splice(to, 0, moved);

    const toolUpdates: ToolbarTool[] = [];
    const featureUpdates: AiFeature[] = [];

    sorted.forEach((item, idx) => {
      const newOrder = (idx + 1) * 10;
      if (item.kind === "tool") {
        const tool = tools.find((t) => t.id === item.id);
        if (tool) toolUpdates.push({ ...tool, sortOrder: newOrder });
      } else {
        const feature = features.find((f) => f.id === item.id);
        if (feature) featureUpdates.push({ ...feature, sortOrder: newOrder });
      }
    });

    if (toolUpdates.length > 0) {
      const nextTools = tools.map((t) => toolUpdates.find((u) => u.id === t.id) ?? t);
      setTools(nextTools);
      await saveToolbarTools(nextTools);
    }
    for (const f of featureUpdates) {
      await saveAiFeature(f);
    }
    if (featureUpdates.length > 0) {
      setFeatures((prev) => prev.map((f) => featureUpdates.find((u) => u.id === f.id) ?? f));
    }
    await notifyChanged();
  }

  // --- Tool Config ---

  async function updateToolConfig(toolId: string, config: Record<string, unknown>) {
    const next = tools.map((t) => t.id === toolId ? { ...t, config } : t);
    setTools(next);
    await saveToolbarTools(next);
    setDraft((current) => {
      if (current?.kind === "tool" && current.data.id === toolId) {
        return { ...current, data: { ...current.data, config } };
      }
      return current;
    });
  }

  // --- Feature CRUD ---

  function createFeature() {
    const sortOrder = features.reduce((max, f) => Math.max(max, f.sortOrder), 0) + 10;
    setDraft({
      kind: "feature",
      data: {
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
      },
    });
  }

  async function saveFeatureDraft() {
    if (draft?.kind !== "feature") return;
    setStatus("Saving...");
    setError("");
    try {
      await saveAiFeature(draft.data);
      await refresh();
      await notifyChanged();
      setStatus("Saved");
    } catch (e) {
      setError(errorMessage(e, "Feature was not saved."));
      setStatus("");
    }
  }

  async function removeFeature(feature: AiFeature) {
    if (feature.kind !== "custom") return;
    setStatus("Deleting...");
    setError("");
    try {
      await deleteAiFeature(feature.id);
      const next = features.filter((f) => f.id !== feature.id);
      setFeatures(next);
      setDraft(next.length > 0 ? { kind: "feature", data: next[0] } : { kind: "toolbar-config" });
      await notifyChanged();
      setStatus("Deleted");
    } catch (e) {
      setError(errorMessage(e, "Feature was not deleted."));
      setStatus("");
    }
  }

  function updateFeatureDraft(update: Partial<AiFeature>) {
    setDraft((c) => c?.kind === "feature" ? { ...c, data: { ...c.data, ...update } } : c);
    setStatus("");
  }

  // --- Selected ID tracking ---

  const selectedId = draft?.kind === "feature" ? draft.data.id
    : draft?.kind === "tool" ? draft.data.id
    : draft?.kind === "toolbar-config" ? "__toolbar__"
    : "__panel__";

  return (
    <div className="grid h-full min-h-0 gap-3 overflow-hidden lg:grid-cols-[220px_1fr]">
      {/* Left Panel */}
      <Card className="grid h-full min-h-0 content-start gap-3 overflow-y-auto px-2.5 py-3">
        {/* Config Section */}
        <SectionLabel>Config</SectionLabel>
        <NavItem
          icon={<ToolbarIcon />}
          label="Toolbar"
          active={selectedId === "__toolbar__"}
          onClick={() => setDraft({ kind: "toolbar-config" })}
        />
        <NavItem
          icon={<PanelIcon />}
          label="Panel"
          active={selectedId === "__panel__"}
          onClick={() => setDraft({ kind: "panel-config" })}
        />

        {/* Tools Section */}
        <SectionLabel>Tools</SectionLabel>
        {[...tools].sort((a, b) => a.sortOrder - b.sortOrder).map((tool) => (
          <NavItem
            key={tool.id}
            icon={<FeatureIcon icon={tool.icon} size={15} />}
            label={tool.name}
            badge={!tool.enabled ? "off" : undefined}
            active={selectedId === tool.id}
            onClick={() => setDraft({ kind: "tool", data: tool })}
          />
        ))}

        {/* Features Section */}
        <div className="flex items-center justify-between">
          <SectionLabel>Features</SectionLabel>
          <Button aria-label="New feature" onClick={createFeature} icon={<Plus size={14} />} />
        </div>
        {features.map((f) => (
          <NavItem
            key={f.id}
            icon={<FeatureIcon icon={f.icon} size={15} />}
            label={f.name}
            badge={!f.enabled ? "off" : undefined}
            active={selectedId === f.id}
            onClick={() => setDraft({ kind: "feature", data: f })}
          />
        ))}
      </Card>

      {/* Right Panel */}
      <Card className="grid h-full min-h-0 content-start gap-3 overflow-y-auto">
        {draft?.kind === "toolbar-config" ? (
          <ToolbarConfigPanel
            items={allToolbarItems}
            enabledItems={enabledToolbarItems}
            onReorder={(from, to) => void applyReorder(from, to)}
            onToggle={toggleToolbarItem}
          />
        ) : draft?.kind === "panel-config" ? (
          <PanelConfigPanel />
        ) : draft?.kind === "tool" ? (
          <ToolConfigPanel tool={draft.data} onUpdateConfig={(c) => void updateToolConfig(draft.data.id, c)} />
        ) : draft?.kind === "feature" ? (
          <FeatureConfigPanel
            draft={draft.data}
            activeFeature={activeFeature}
            status={status}
            error={error}
            onUpdate={updateFeatureDraft}
            onSave={() => void saveFeatureDraft()}
            onRemove={() => void removeFeature(draft.data)}
          />
        ) : null}
      </Card>
    </div>
  );
}

/* ========== Left Panel Primitives ========== */

function SectionLabel({ children }: { children: React.ReactNode }) {
  return <h3 className="text-xs font-semibold uppercase tracking-wider text-muted">{children}</h3>;
}

function NavItem({ icon, label, badge, active, onClick }: {
  icon: React.ReactNode;
  label: string;
  badge?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      className={`flex items-center gap-2 rounded-md px-2 py-1.5 text-left transition ${
        active ? "bg-accent/10 text-accent" : "text-strong hover:bg-surfaceHover"
      }`}
      onClick={onClick}
      type="button"
    >
      {icon}
      <span className="min-w-0 flex-1 truncate text-sm">{label}</span>
      {badge ? <span className="text-[10px] text-muted">{badge}</span> : null}
    </button>
  );
}

function ToolbarIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 15 15" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <rect x="1" y="4" width="13" height="7" rx="2" />
      <circle cx="4.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
      <circle cx="7.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
      <circle cx="10.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
    </svg>
  );
}

function PanelIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 15 15" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round">
      <rect x="1" y="1" width="13" height="13" rx="2" />
      <line x1="1" y1="5" x2="14" y2="5" />
    </svg>
  );
}

/* ========== Right Panel: Toolbar Config ========== */

function ToolbarConfigPanel({ items, enabledItems, onReorder, onToggle }: {
  items: Array<{ id: string; name: string; icon: AiFeatureIcon; enabled: boolean; sortOrder: number; kind: "tool" | "ai" }>;
  enabledItems: Array<{ id: string; name: string; icon: AiFeatureIcon; enabled: boolean }>;
  onReorder: (from: number, to: number) => void;
  onToggle: (item: { id: string; kind: "tool" | "ai" }) => void;
}) {
  const [dragIdx, setDragIdx] = useState<number | null>(null);
  const [dropIdx, setDropIdx] = useState<number | null>(null);
  const rowRefs = useRef<(HTMLDivElement | null)[]>([]);
  const dragging = useRef(false);

  function handlePointerDown(idx: number, e: React.PointerEvent) {
    dragging.current = true;
    setDragIdx(idx);
    setDropIdx(null);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  }

  function handlePointerMove(e: React.PointerEvent) {
    if (!dragging.current || dragIdx === null) return;
    const y = e.clientY;
    let found: number | null = null;
    for (let i = 0; i < items.length; i++) {
      const el = rowRefs.current[i];
      if (!el) continue;
      const rect = el.getBoundingClientRect();
      if (y >= rect.top && y <= rect.bottom && i !== dragIdx) {
        found = i;
        break;
      }
    }
    if (found !== dropIdx) setDropIdx(found);
  }

  function handlePointerUp() {
    if (dragging.current && dragIdx !== null && dropIdx !== null && dragIdx !== dropIdx) {
      onReorder(dragIdx, dropIdx);
    }
    dragging.current = false;
    setDragIdx(null);
    setDropIdx(null);
  }

  return (
    <>
      <div>
        <h2 className="text-lg font-semibold">Toolbar Config</h2>
        <p className="text-sm text-muted">Drag to reorder. Toggle to show/hide.</p>
      </div>

      {/* Preview — mimics native macOS toolbar */}
      <div className="flex justify-center py-2">
        <div
          className="inline-flex items-center gap-px rounded-[8px] px-1 py-1 shadow-lg"
          style={{ background: "rgba(18,18,18,0.94)" }}
        >
          {enabledItems.map((item) => (
            <div
              className="flex items-center justify-center rounded-md text-white/80"
              key={item.id}
              style={{ width: 34, height: 30 }}
              title={item.name}
            >
              <FeatureIcon icon={item.icon} size={16} />
            </div>
          ))}
          {enabledItems.length === 0 && (
            <p className="px-3 py-1 text-xs text-white/30">No items</p>
          )}
        </div>
      </div>

      {/* Draggable item list */}
      <div className="grid gap-1" onPointerMove={handlePointerMove} onPointerUp={handlePointerUp}>
        {items.map((item, idx) => (
          <div
            key={item.id}
            ref={(el) => { rowRefs.current[idx] = el; }}
            className={`flex items-center gap-2 rounded-md border px-2.5 py-2 transition select-none ${
              dragIdx === idx
                ? "border-accent bg-accent/10 opacity-50"
                : dropIdx === idx
                  ? "border-accent bg-accent/5"
                  : "border-border bg-surface hover:bg-surfaceHover"
            }`}
          >
            <div
              className="cursor-grab text-muted active:cursor-grabbing"
              onPointerDown={(e) => handlePointerDown(idx, e)}
            >
              <svg width="10" height="16" viewBox="0 0 10 16" fill="currentColor">
                <circle cx="3" cy="2" r="1.5" /><circle cx="7" cy="2" r="1.5" />
                <circle cx="3" cy="8" r="1.5" /><circle cx="7" cy="8" r="1.5" />
                <circle cx="3" cy="14" r="1.5" /><circle cx="7" cy="14" r="1.5" />
              </svg>
            </div>
            <FeatureIcon icon={item.icon} size={15} />
            <span className="min-w-0 flex-1 truncate text-sm text-strong">{item.name}</span>
            <span className="text-[10px] text-muted">{item.kind === "tool" ? "Tool" : "AI"}</span>
            <button
              className={`relative inline-flex shrink-0 items-center rounded-full transition-colors ${
                item.enabled ? "bg-accent" : "bg-border"
              }`}
              onClick={(e) => { e.stopPropagation(); onToggle(item); }}
              style={{ width: 28, height: 16 }}
              type="button"
            >
              <span
                className={`absolute rounded-full bg-white shadow-sm transition-all ${
                  item.enabled ? "right-0.5" : "left-0.5"
                }`}
                style={{ width: 12, height: 12, top: 2 }}
              />
            </button>
          </div>
        ))}
      </div>
    </>
  );
}

/* ========== Right Panel: Panel Config ========== */

function PanelConfigPanel() {
  return (
    <>
      <div>
        <h2 className="text-lg font-semibold">Panel Config</h2>
        <p className="text-sm text-muted">Configure the popup panel behavior and appearance.</p>
      </div>
      <div className="rounded-md border border-border bg-surface px-3 py-2">
        <p className="text-sm text-muted">Panel configuration options coming soon.</p>
      </div>
    </>
  );
}

/* ========== Right Panel: Tool Config ========== */

function ToolConfigPanel({ tool, onUpdateConfig }: { tool: ToolbarTool; onUpdateConfig: (config: Record<string, unknown>) => void }) {
  const config = tool.config;

  return (
    <>
      <div className="flex items-start justify-between gap-2.5">
        <div>
          <h2 className="text-lg font-semibold">{tool.name}</h2>
          <p className="text-sm text-muted">{TOOL_DESCRIPTIONS[tool.id]}</p>
        </div>
      </div>

      {tool.id === "copy" && (
        <div className="rounded-md border border-border bg-surface px-3 py-2">
          <p className="text-sm text-muted">Copies selected text to clipboard. No additional configuration.</p>
        </div>
      )}

      {tool.id === "search" && (
        <div className="grid gap-2.5">
          <Field label="Search engine">
            <Select
              value={(config.engine as string) ?? "google"}
              onChange={(e) => onUpdateConfig({ ...config, engine: e.target.value })}
            >
              <option value="google">Google</option>
              <option value="bing">Bing</option>
              <option value="duckduckgo">DuckDuckGo</option>
              <option value="custom">Custom URL</option>
            </Select>
          </Field>
          {config.engine === "custom" && (
            <Field label="Custom search URL" hint="Use {query} as placeholder for the search text.">
              <Input
                value={(config.customUrl as string) ?? ""}
                onChange={(e) => onUpdateConfig({ ...config, customUrl: e.target.value })}
                placeholder="https://example.com/search?q={query}"
              />
            </Field>
          )}
        </div>
      )}

      {tool.id === "read" && (
        <div className="grid gap-2.5">
          <Field label="TTS Engine">
            <Select
              value={(config.engine as string) ?? "system"}
              onChange={(e) => onUpdateConfig({ ...config, engine: e.target.value })}
            >
              <option value="system">System built-in (macOS say)</option>
              <option value="api">API service</option>
            </Select>
          </Field>
          {config.engine === "api" && (
            <>
              <Field label="API URL" hint="TTS service endpoint that accepts POST with text.">
                <Input
                  value={(config.apiUrl as string) ?? ""}
                  onChange={(e) => onUpdateConfig({ ...config, apiUrl: e.target.value })}
                  placeholder="https://api.example.com/tts"
                />
              </Field>
              <Field label="Voice" hint="Voice name or ID for the API service.">
                <Input
                  value={(config.voice as string) ?? ""}
                  onChange={(e) => onUpdateConfig({ ...config, voice: e.target.value })}
                  placeholder="alloy"
                />
              </Field>
            </>
          )}
        </div>
      )}
    </>
  );
}

/* ========== Right Panel: Feature Config ========== */

function FeatureConfigPanel({ draft, activeFeature, status, error, onUpdate, onSave, onRemove }: {
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
            <Button onClick={onRemove} variant="danger" icon={<Trash2 size={16} />}>Delete</Button>
          ) : null}
          <Button onClick={onSave} variant="primary" icon={<Save size={16} />}>Save</Button>
        </div>
      </div>

      <div className="grid gap-2.5 md:grid-cols-2">
        <Field label="Name">
          <Input disabled={draft.kind !== "custom"} onChange={(e) => onUpdate({ name: e.target.value })} value={draft.name} />
        </Field>
        <Field label="Sort order">
          <Input onChange={(e) => onUpdate({ sortOrder: Number(e.target.value) })} type="number" value={draft.sortOrder} />
        </Field>
        <Field label="Icon" hint="Shown on the popup action button.">
          <Select onChange={(e) => onUpdate({ icon: selectedFeatureIcon(e.target.value) })} value={draft.icon}>
            {FEATURE_ICON_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
          </Select>
        </Field>
        {draft.kind === "translation" ? (
          <Field label="Target language">
            <Input onChange={(e) => onUpdate({ targetLanguage: e.target.value })} value={draft.targetLanguage} />
          </Field>
        ) : null}
        {draft.kind === "review" ? (
          <Field label="Display interval" hint="Seconds between vocabulary cards in the popup.">
            <Input min={5} onChange={(e) => onUpdate({ reviewIntervalSeconds: Number(e.target.value) })} type="number" value={draft.reviewIntervalSeconds} />
          </Field>
        ) : null}
      </div>

      <label className="flex items-center gap-3 text-sm text-strong">
        <input checked={draft.speechEnabled} className="h-4 w-4 accent-[rgb(var(--color-accent))]" onChange={(e) => onUpdate({ speechEnabled: e.target.checked })} type="checkbox" />
        Show speech button in the popup
      </label>

      {draft.kind === "translation" ? (
        <label className="flex items-center gap-3 text-sm text-strong">
          <input checked={draft.autoSaveToVocabulary} className="h-4 w-4 accent-[rgb(var(--color-accent))]" onChange={(e) => onUpdate({ autoSaveToVocabulary: e.target.checked })} type="checkbox" />
          Auto-save translations to vocabulary
        </label>
      ) : null}

      {draft.kind !== "review" ? (
        <div className="rounded-md border border-border bg-surface px-3 py-2">
          <p className="text-sm font-medium text-strong">Popup actions</p>
          <p className="mt-1 text-xs leading-5 text-muted">This feature appears as an icon action next to the popup input.</p>
        </div>
      ) : null}

      {draft.kind !== "review" ? (
        <Field label="Prompt" hint="Use {{text}} for selected/input text. Translation also supports {{targetLanguage}}.">
          <Textarea className="min-h-64 font-mono" onChange={(e) => onUpdate({ promptTemplate: e.target.value })} value={draft.promptTemplate} />
        </Field>
      ) : null}

      <div className="rounded-md border border-border bg-example px-3 py-2 text-xs leading-5 text-muted">
        Output: {draft.kind === "review" ? "vocabulary cards" : draft.outputMode === "translation_json" ? "structured translation JSON" : "plain text"}.{status ? ` ${status}.` : ""}
      </div>
      {error ? <div className="rounded-md border border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger">{error}</div> : null}
    </>
  );
}

/* ========== Shared ========== */

async function notifyChanged() {
  if (isTauriRuntime()) {
    await emit("englist://features-changed");
  }
}

function selectedFeatureIcon(value: string): AiFeatureIcon {
  return isFeatureIcon(value) ? value : "wand";
}
