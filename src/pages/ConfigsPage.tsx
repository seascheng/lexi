import { emit } from "@tauri-apps/api/event";
import { Eye, EyeOff, Layers, Plus, Save, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";
import type {
  AiFeature,
  AiFeatureIcon,
  AppSettings,
  Panel,
  ToolbarTool,
} from "../types";
import {
  DEFAULT_CUSTOM_PROMPT_TEMPLATE,
  DEFAULT_SETTINGS,
  TOOL_DESCRIPTIONS,
} from "../lib/defaults";
import {
  deleteAiFeature,
  listAiFeatures,
  listPanels,
  loadSettings,
  loadToolbarTools,
  saveAiFeature,
  savePanel,
  saveSettings,
  saveToolbarTools,
} from "../lib/database";
import { errorMessage } from "../lib/errors";
import {
  FEATURE_ICON_OPTIONS,
  FeatureIcon,
  isFeatureIcon,
} from "../lib/featureIcons";
import { syncNativeToolbar } from "../lib/nativeToolbar";
import { isTauriRuntime } from "../lib/platform";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { Field, Input, Select, Textarea } from "../components/ui/Field";

type DraftItem =
  | { kind: "toolbar-config" }
  | { kind: "panel-config" }
  | { kind: "panels-config" }
  | { kind: "tool"; data: ToolbarTool }
  | { kind: "feature"; data: AiFeature };

export function ConfigsPage() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [tools, setTools] = useState<ToolbarTool[]>([]);
  const [panels, setPanels] = useState<Panel[]>([]);
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [draft, setDraft] = useState<DraftItem | null>(null);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");

  const activeFeature = useMemo(
    () =>
      draft?.kind === "feature"
        ? features.find((f) => f.id === draft.data.id)
        : undefined,
    [draft, features],
  );

  useEffect(() => {
    void refresh();
  }, []);

  async function refresh() {
    const [nextFeatures, nextTools, nextSettings, loadedPanels] = await Promise.all([
      listAiFeatures(),
      loadToolbarTools(),
      loadSettings(),
      listPanels(),
    ]);
    setFeatures(nextFeatures);
    setTools(nextTools);
    setSettings(nextSettings);
    setPanels(loadedPanels);
    setDraft((current) => current ?? { kind: "toolbar-config" });
  }

  // --- Toolbar Config ---

  const allToolbarItems = useMemo(() => {
    const items: Array<{
      id: string;
      name: string;
      icon: AiFeatureIcon;
      enabled: boolean;
      sortOrder: number;
      kind: "tool" | "ai";
    }> = [
      ...tools.map((t) => ({
        id: t.id,
        name: t.name,
        icon: t.icon,
        enabled: t.enabled,
        sortOrder: t.sortOrder,
        kind: "tool" as const,
      })),
      ...features.map((f) => ({
          id: f.id,
          name: f.name,
          icon: f.icon,
          enabled: f.enabled,
          sortOrder: f.sortOrder,
          kind: "ai" as const,
        })),
    ];
    return items.sort((a, b) => a.sortOrder - b.sortOrder);
  }, [tools, features]);

  const enabledToolbarItems = allToolbarItems.filter((i) => i.enabled);

  async function toggleToolbarItem(item: { id: string; kind: "tool" | "ai" }) {
    let nextFeatures = features;
    let nextTools = tools;

    if (item.kind === "tool") {
      nextTools = tools.map((t) =>
        t.id === item.id ? { ...t, enabled: !t.enabled } : t,
      );
      setTools(nextTools);
      await saveToolbarTools(nextTools);
    } else {
      const feature = features.find((f) => f.id === item.id);
      if (!feature) return;
      const updated = { ...feature, enabled: !feature.enabled };
      await saveAiFeature(updated);
      nextFeatures = features.map((f) => (f.id === updated.id ? updated : f));
      setFeatures(nextFeatures);
    }
    await syncNativeToolbar(settings, nextFeatures, nextTools);
    await notifyChanged();
  }

  async function toggleToolbarEnabled(enabled: boolean) {
    const next = { ...settings, toolbarEnabled: enabled };
    setSettings(next);
    await saveSettings(next);
    await syncNativeToolbar(next, features, tools);
    await notifyChanged();
  }

  async function applyToolbarReorder(from: number, to: number) {
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

    const nextTools =
      toolUpdates.length > 0
        ? tools.map((t) => toolUpdates.find((u) => u.id === t.id) ?? t)
        : tools;
    const nextFeatures =
      featureUpdates.length > 0
        ? features.map((f) => featureUpdates.find((u) => u.id === f.id) ?? f)
        : features;

    if (toolUpdates.length > 0) {
      setTools(nextTools);
      await saveToolbarTools(nextTools);
    }
    for (const f of featureUpdates) {
      await saveAiFeature(f);
    }
    if (featureUpdates.length > 0) {
      setFeatures(nextFeatures);
    }
    await syncNativeToolbar(settings, nextFeatures, nextTools);
    await notifyChanged();
  }

  // --- Panel Config ---

  const allPanelItems = useMemo(() => {
    const items: Array<{
      id: string;
      name: string;
      icon: AiFeatureIcon;
      enabled: boolean;
      sortOrder: number;
      kind: "tool" | "ai";
    }> = [
      ...tools.map((t) => ({
        id: t.id,
        name: t.name,
        icon: t.icon,
        enabled: t.panelEnabled,
        sortOrder: t.panelSortOrder,
        kind: "tool" as const,
      })),
      ...features.map((f) => ({
          id: f.id,
          name: f.name,
          icon: f.icon,
          enabled: f.panelEnabled,
          sortOrder: f.panelSortOrder,
          kind: "ai" as const,
        })),
    ];
    return items.sort((a, b) => a.sortOrder - b.sortOrder);
  }, [tools, features]);

  async function togglePanelItem(item: { id: string; kind: "tool" | "ai" }) {
    if (item.kind === "tool") {
      const next = tools.map((t) =>
        t.id === item.id ? { ...t, panelEnabled: !t.panelEnabled } : t,
      );
      setTools(next);
      await saveToolbarTools(next);
    } else {
      const feature = features.find((f) => f.id === item.id);
      if (!feature) return;
      const updated = { ...feature, panelEnabled: !feature.panelEnabled };
      await saveAiFeature(updated);
      setFeatures((prev) =>
        prev.map((f) => (f.id === updated.id ? updated : f)),
      );
    }
    await notifyChanged();
  }

  async function applyPanelReorder(from: number, to: number) {
    const sorted = [...allPanelItems];
    const [moved] = sorted.splice(from, 1);
    sorted.splice(to, 0, moved);

    const toolUpdates: ToolbarTool[] = [];
    const featureUpdates: AiFeature[] = [];

    sorted.forEach((item, idx) => {
      const newOrder = (idx + 1) * 10;
      if (item.kind === "tool") {
        const tool = tools.find((t) => t.id === item.id);
        if (tool) toolUpdates.push({ ...tool, panelSortOrder: newOrder });
      } else {
        const feature = features.find((f) => f.id === item.id);
        if (feature)
          featureUpdates.push({ ...feature, panelSortOrder: newOrder });
      }
    });

    if (toolUpdates.length > 0) {
      const nextTools = tools.map(
        (t) => toolUpdates.find((u) => u.id === t.id) ?? t,
      );
      setTools(nextTools);
      await saveToolbarTools(nextTools);
    }
    for (const f of featureUpdates) {
      await saveAiFeature(f);
    }
    if (featureUpdates.length > 0) {
      setFeatures((prev) =>
        prev.map((f) => featureUpdates.find((u) => u.id === f.id) ?? f),
      );
    }
    await notifyChanged();
  }

  // --- Tool Config ---

  async function updateToolConfig(
    toolId: string,
    config: Record<string, unknown>,
  ) {
    const next = tools.map((t) => (t.id === toolId ? { ...t, config } : t));
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
    const sortOrder =
      features.reduce((max, f) => Math.max(max, f.sortOrder), 0) + 10;
    const panelSortOrder =
      features.reduce((max, f) => Math.max(max, f.panelSortOrder), 0) + 10;
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
        panelEnabled: true,
        panelSortOrder,
        autoSaveToVocabulary: false,
        targetLanguage: "",
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
      setDraft(
        next.length > 0
          ? { kind: "feature", data: next[0] }
          : { kind: "toolbar-config" },
      );
      await notifyChanged();
      setStatus("Deleted");
    } catch (e) {
      setError(errorMessage(e, "Feature was not deleted."));
      setStatus("");
    }
  }

  function updateFeatureDraft(update: Partial<AiFeature>) {
    setDraft((c) =>
      c?.kind === "feature" ? { ...c, data: { ...c.data, ...update } } : c,
    );
    setStatus("");
  }

  // --- Panels Config ---

  async function savePanelDraft(panel: Panel) {
    await savePanel(panel);
    setPanels(await listPanels());
  }

  // --- Selected ID tracking ---

  const selectedId =
    draft?.kind === "feature"
      ? draft.data.id
      : draft?.kind === "tool"
        ? draft.data.id
        : draft?.kind === "toolbar-config"
          ? "__toolbar__"
          : draft?.kind === "panels-config"
            ? "__panels__"
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
        <NavItem
          icon={<Layers size={15} />}
          label="Panels"
          active={selectedId === "__panels__"}
          onClick={() => setDraft({ kind: "panels-config" })}
        />

        {/* Tools Section */}
        <SectionLabel>Tools</SectionLabel>
        {[...tools]
          .sort((a, b) => a.sortOrder - b.sortOrder)
          .map((tool) => (
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
          <Button
            aria-label="New feature"
            onClick={createFeature}
            icon={<Plus size={14} />}
          />
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
            toolbarEnabled={settings.toolbarEnabled}
            toolbarTheme={settings.theme}
            onToggleToolbarEnabled={toggleToolbarEnabled}
            onReorder={(from, to) => void applyToolbarReorder(from, to)}
            onToggle={toggleToolbarItem}
          />
        ) : draft?.kind === "panel-config" ? (
          <PanelConfigPanel
            items={allPanelItems}
            onToggle={togglePanelItem}
            onReorder={(from, to) => void applyPanelReorder(from, to)}
          />
        ) : draft?.kind === "panels-config" ? (
          <PanelsConfigPanel panels={panels} onSave={savePanelDraft} />
        ) : draft?.kind === "tool" ? (
          <ToolConfigPanel
            tool={draft.data}
            onUpdateConfig={(c) => void updateToolConfig(draft.data.id, c)}
          />
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
  return (
    <h3 className="text-xs font-semibold uppercase tracking-wider text-muted">
      {children}
    </h3>
  );
}

function NavItem({
  icon,
  label,
  badge,
  active,
  onClick,
}: {
  icon: React.ReactNode;
  label: string;
  badge?: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      className={`flex items-center gap-2 rounded-md px-2 py-1.5 text-left transition ${
        active
          ? "bg-accent/10 text-accent"
          : "text-strong hover:bg-surfaceHover"
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
    <svg
      width="15"
      height="15"
      viewBox="0 0 15 15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="1" y="4" width="13" height="7" rx="2" />
      <circle cx="4.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
      <circle cx="7.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
      <circle cx="10.5" cy="7.5" r="1" fill="currentColor" stroke="none" />
    </svg>
  );
}

function PanelIcon() {
  return (
    <svg
      width="15"
      height="15"
      viewBox="0 0 15 15"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <rect x="1" y="1" width="13" height="13" rx="2" />
      <line x1="1" y1="5" x2="14" y2="5" />
    </svg>
  );
}

/* ========== Right Panel: Toolbar Config ========== */

function ToolbarConfigPanel({
  items,
  enabledItems,
  toolbarEnabled,
  toolbarTheme,
  onToggleToolbarEnabled,
  onReorder,
  onToggle,
}: {
  items: Array<{
    id: string;
    name: string;
    icon: AiFeatureIcon;
    enabled: boolean;
    sortOrder: number;
    kind: "tool" | "ai";
  }>;
  enabledItems: Array<{
    id: string;
    name: string;
    icon: AiFeatureIcon;
    enabled: boolean;
  }>;
  toolbarEnabled: boolean;
  toolbarTheme: AppSettings["theme"];
  onToggleToolbarEnabled: (enabled: boolean) => void;
  onReorder: (from: number, to: number) => void;
  onToggle: (item: { id: string; kind: "tool" | "ai" }) => void;
}) {
  const [dragIdx, setDragIdx] = useState<number | null>(null);
  const [dropIdx, setDropIdx] = useState<number | null>(null);
  const rowRefs = useRef<(HTMLDivElement | null)[]>([]);
  const dragging = useRef(false);
  const previewStyle = toolbarPreviewStyle(toolbarTheme);

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
    if (
      dragging.current &&
      dragIdx !== null &&
      dropIdx !== null &&
      dragIdx !== dropIdx
    ) {
      onReorder(dragIdx, dropIdx);
    }
    dragging.current = false;
    setDragIdx(null);
    setDropIdx(null);
  }

  return (
    <>
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-lg font-semibold">Toolbar Config</h2>
          <p className="text-sm text-muted">
            Drag to reorder. Toggle to show/hide.
          </p>
        </div>
        <ToggleSwitch
          checked={toolbarEnabled}
          onChange={onToggleToolbarEnabled}
        />
      </div>

      {/* Preview — mimics native macOS toolbar */}
      <div className="flex justify-center py-2">
        <div
          className="inline-flex h-[30px] items-center overflow-hidden rounded-[8px] shadow-lg"
          style={{
            background: previewStyle.background,
            opacity: toolbarEnabled ? 1 : 0.55,
          }}
        >
          <div
            className="flex h-[30px] w-[18px] cursor-grab items-center justify-center active:cursor-grabbing"
            style={{ color: previewStyle.handle }}
            title="Move toolbar"
          >
            <ToolbarDragHandleIcon />
          </div>
          {enabledItems.map((item) => (
            <div
              className="flex cursor-pointer items-center justify-center rounded-md"
              key={item.id}
              style={{ width: 34, height: 30, color: previewStyle.icon }}
              title={item.name}
            >
              <FeatureIcon icon={item.icon} size={16} />
            </div>
          ))}
          {enabledItems.length === 0 && (
            <p
              className="px-3 py-1 text-xs"
              style={{ color: previewStyle.muted }}
            >
              No items
            </p>
          )}
        </div>
      </div>

      {/* Draggable item list */}
      <div
        className="grid gap-1"
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
      >
        {items.map((item, idx) => (
          <div
            key={item.id}
            ref={(el) => {
              rowRefs.current[idx] = el;
            }}
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
              <svg
                width="10"
                height="16"
                viewBox="0 0 10 16"
                fill="currentColor"
              >
                <circle cx="3" cy="2" r="1.5" />
                <circle cx="7" cy="2" r="1.5" />
                <circle cx="3" cy="8" r="1.5" />
                <circle cx="7" cy="8" r="1.5" />
                <circle cx="3" cy="14" r="1.5" />
                <circle cx="7" cy="14" r="1.5" />
              </svg>
            </div>
            <FeatureIcon icon={item.icon} size={15} />
            <span className="min-w-0 flex-1 truncate text-sm text-strong">
              {item.name}
            </span>
            <span className="text-[10px] text-muted">
              {item.kind === "tool" ? "Tool" : "AI"}
            </span>
            <ToggleSwitch
              checked={item.enabled}
              onChange={() => onToggle(item)}
            />
          </div>
        ))}
      </div>
    </>
  );
}

function toolbarPreviewStyle(theme: AppSettings["theme"]) {
  if (theme === "light") {
    return {
      background: "rgba(250,250,250,0.94)",
      icon: "rgba(20,20,20,1)",
      handle: "rgba(20,20,20,0.42)",
      muted: "rgba(20,20,20,0.38)",
    };
  }

  return {
    background: "rgba(18,18,18,0.94)",
    icon: "rgba(255,255,255,1)",
    handle: "rgba(255,255,255,0.55)",
    muted: "rgba(255,255,255,0.30)",
  };
}

function ToolbarDragHandleIcon() {
  return (
    <svg
      width="10"
      height="16"
      viewBox="0 0 10 16"
      fill="none"
      aria-hidden="true"
    >
      <line
        x1="3.5"
        y1="3"
        x2="3.5"
        y2="13"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
      />
      <line
        x1="6.5"
        y1="3"
        x2="6.5"
        y2="13"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
      />
    </svg>
  );
}

/* ========== Right Panel: Panel Config ========== */

function PanelConfigPanel({
  items,
  onToggle,
  onReorder,
}: {
  items: Array<{
    id: string;
    name: string;
    icon: AiFeatureIcon;
    enabled: boolean;
    sortOrder: number;
    kind: "tool" | "ai";
  }>;
  onToggle: (item: { id: string; kind: "tool" | "ai" }) => void;
  onReorder: (from: number, to: number) => void;
}) {
  const enabledItems = items.filter((i) => i.enabled);
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
    if (
      dragging.current &&
      dragIdx !== null &&
      dropIdx !== null &&
      dragIdx !== dropIdx
    ) {
      onReorder(dragIdx, dropIdx);
    }
    dragging.current = false;
    setDragIdx(null);
    setDropIdx(null);
  }

  return (
    <>
      <div>
        <h2 className="text-lg font-semibold">Panel Config</h2>
        <p className="text-sm text-muted">
          Configure action buttons in the popup input area.
        </p>
      </div>

      {/* Preview — popup action bar */}
      <div className="flex justify-center py-2">
        <div className="inline-flex items-center gap-0.5 rounded-lg border border-border bg-surface px-2 py-1.5">
          {enabledItems.map((item) => (
            <div
              className="flex h-7 w-7 items-center justify-center rounded-md text-strong"
              key={item.id}
              title={item.name}
            >
              <FeatureIcon icon={item.icon} size={15} />
            </div>
          ))}
          {enabledItems.length === 0 && (
            <p className="px-2 text-xs text-muted">No actions enabled</p>
          )}
        </div>
      </div>

      {/* Item list with drag-and-drop */}
      <div
        className="grid gap-1"
        onPointerMove={handlePointerMove}
        onPointerUp={handlePointerUp}
      >
        {items.map((item, idx) => (
          <div
            key={item.id}
            ref={(el) => {
              rowRefs.current[idx] = el;
            }}
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
              <svg
                width="10"
                height="16"
                viewBox="0 0 10 16"
                fill="currentColor"
              >
                <circle cx="3" cy="2" r="1.5" />
                <circle cx="7" cy="2" r="1.5" />
                <circle cx="3" cy="8" r="1.5" />
                <circle cx="7" cy="8" r="1.5" />
                <circle cx="3" cy="14" r="1.5" />
                <circle cx="7" cy="14" r="1.5" />
              </svg>
            </div>
            <FeatureIcon icon={item.icon} size={15} />
            <span className="min-w-0 flex-1 truncate text-sm text-strong">
              {item.name}
            </span>
            <span className="text-[10px] text-muted">
              {item.kind === "tool" ? "Tool" : "AI"}
            </span>
            <ToggleSwitch
              checked={item.enabled}
              onChange={() => onToggle(item)}
            />
          </div>
        ))}
      </div>
    </>
  );
}

/* ========== Right Panel: Tool Config ========== */

function ToolConfigPanel({
  tool,
  onUpdateConfig,
}: {
  tool: ToolbarTool;
  onUpdateConfig: (config: Record<string, unknown>) => void;
}) {
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
          <p className="text-sm text-muted">
            Copies selected text to clipboard. No additional configuration.
          </p>
        </div>
      )}

      {tool.id === "search" && (
        <div className="grid gap-2.5">
          <Field label="Search engine">
            <Select
              value={(config.engine as string) ?? "google"}
              onChange={(e) =>
                onUpdateConfig({ ...config, engine: e.target.value })
              }
            >
              <option value="google">Google</option>
              <option value="bing">Bing</option>
              <option value="duckduckgo">DuckDuckGo</option>
              <option value="custom">Custom URL</option>
            </Select>
          </Field>
          {config.engine === "custom" && (
            <Field
              label="Custom search URL"
              hint="Use {query} as placeholder for the search text."
            >
              <Input
                value={(config.customUrl as string) ?? ""}
                onChange={(e) =>
                  onUpdateConfig({ ...config, customUrl: e.target.value })
                }
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
              onChange={(e) =>
                onUpdateConfig({ ...config, engine: e.target.value })
              }
            >
              <option value="system">System built-in (macOS say)</option>
              <option value="api">API service</option>
            </Select>
          </Field>
          {config.engine === "api" && (
            <>
              <Field
                label="API URL"
                hint="TTS service endpoint that accepts POST with text."
              >
                <Input
                  value={(config.apiUrl as string) ?? ""}
                  onChange={(e) =>
                    onUpdateConfig({ ...config, apiUrl: e.target.value })
                  }
                  placeholder="https://api.example.com/tts"
                />
              </Field>
              <Field label="Voice" hint="Voice name or ID for the API service.">
                <Input
                  value={(config.voice as string) ?? ""}
                  onChange={(e) =>
                    onUpdateConfig({ ...config, voice: e.target.value })
                  }
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

function FeatureConfigPanel({
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
          <h2 className="text-lg font-semibold">
            {activeFeature ? "Edit feature" : "New feature"}
          </h2>
          <p className="text-sm text-muted">
            {draft.kind === "translation"
              ? "Built-in translation feature for selected text."
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
            <Button
              onClick={onRemove}
              variant="danger"
              icon={<Trash2 size={16} />}
            >
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
            onChange={(e) => onUpdate({ name: e.target.value })}
            value={draft.name}
          />
        </Field>
        <Field label="Icon">
          <Select
            onChange={(e) =>
              onUpdate({ icon: selectedFeatureIcon(e.target.value) })
            }
            value={draft.icon}
          >
            {FEATURE_ICON_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </Select>
        </Field>
        {draft.kind === "translation" ? (
          <Field label="Target language">
            <Input
              onChange={(e) => onUpdate({ targetLanguage: e.target.value })}
              value={draft.targetLanguage}
            />
          </Field>
        ) : null}
      </div>

      {draft.kind === "translation" ? (
        <label className="flex items-center gap-3 text-sm text-strong">
          <input
            checked={draft.autoSaveToVocabulary}
            className="h-4 w-4 accent-[rgb(var(--color-accent))]"
            onChange={(e) =>
              onUpdate({ autoSaveToVocabulary: e.target.checked })
            }
            type="checkbox"
          />
          Auto-save translations to vocabulary
        </label>
      ) : null}

      <Field
        label="Prompt"
        hint="Use {{text}} for selected/input text. Translation also supports {{targetLanguage}}."
      >
        <Textarea
          className="min-h-64 font-mono"
          onChange={(e) => onUpdate({ promptTemplate: e.target.value })}
          value={draft.promptTemplate}
        />
      </Field>

      <div className="rounded-md border border-border bg-example px-3 py-2 text-xs leading-5 text-muted">
        Output:{" "}
        {draft.outputMode === "translation_json"
          ? "structured translation JSON"
          : "plain text"}
        .{status ? ` ${status}.` : ""}
      </div>
      {error ? (
        <div className="rounded-md border border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger">
          {error}
        </div>
      ) : null}
    </>
  );
}

/* ========== Right Panel: Panels Config ========== */

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
              <FeatureIcon icon={panel.icon} size={16} />
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

/* ========== Shared ========== */

function ToggleSwitch({
  checked,
  onChange,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <button
      className={`relative inline-flex shrink-0 items-center rounded-full transition-colors ${
        checked ? "bg-accent" : "bg-border"
      }`}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!checked);
      }}
      style={{ width: 28, height: 16 }}
      type="button"
    >
      <span
        className={`absolute rounded-full bg-white shadow-sm transition-all ${
          checked ? "right-0.5" : "left-0.5"
        }`}
        style={{ width: 12, height: 12, top: 2 }}
      />
    </button>
  );
}

async function notifyChanged() {
  if (isTauriRuntime()) {
    await emit("englist://features-changed");
  }
}

function selectedFeatureIcon(value: string): AiFeatureIcon {
  return isFeatureIcon(value) ? value : "wand";
}
