import { emit } from "@tauri-apps/api/event";
import { useEffect, useMemo, useRef, useState } from "react";
import type { AiFeature, AiFeatureIcon, ToolbarTool } from "../types";
import { TOOL_DESCRIPTIONS } from "../lib/defaults";
import { listAiFeatures, loadToolbarTools, saveAiFeature, saveToolbarTools } from "../lib/database";
import { FeatureIcon } from "../lib/featureIcons";
import { isTauriRuntime } from "../lib/platform";
import { Card } from "../components/ui/Card";

interface ToolbarItem {
  id: string;
  name: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
  kind: "tool" | "ai";
}

export function ToolbarPage() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [tools, setTools] = useState<ToolbarTool[]>([]);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [dropIndex, setDropIndex] = useState<number | null>(null);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    void refresh();
  }, []);

  async function refresh() {
    const [nextFeatures, nextTools] = await Promise.all([listAiFeatures(), loadToolbarTools()]);
    setFeatures(nextFeatures);
    setTools(nextTools);
  }

  const allItems = useMemo((): ToolbarItem[] => {
    const items: ToolbarItem[] = [
      ...tools.map((tool) => ({
        id: tool.id,
        name: tool.name,
        icon: tool.icon,
        enabled: tool.enabled,
        sortOrder: tool.sortOrder,
        kind: "tool" as const,
      })),
      ...features
        .filter((f) => f.kind !== "review")
        .map((f) => ({
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

  const enabledItems = allItems.filter((item) => item.enabled);

  async function toggleItem(item: ToolbarItem) {
    if (item.kind === "tool") {
      const nextTools = tools.map((t) =>
        t.id === item.id ? { ...t, enabled: !t.enabled } : t,
      );
      setTools(nextTools);
      await saveToolbarTools(nextTools);
    } else {
      const feature = features.find((f) => f.id === item.id);
      if (!feature) return;
      const updated = { ...feature, enabled: !feature.enabled };
      await saveAiFeature(updated);
      setFeatures((prev) => prev.map((f) => (f.id === updated.id ? updated : f)));
    }
    await notifyChanged();
  }

  async function applyReorder(fromIdx: number, toIdx: number) {
    const sorted = [...allItems].sort((a, b) => a.sortOrder - b.sortOrder);
    const [moved] = sorted.splice(fromIdx, 1);
    sorted.splice(toIdx, 0, moved);

    // Reassign sortOrder for all items based on new positions
    const updatedTools: ToolbarTool[] = [];
    const updatedFeatures: AiFeature[] = [];

    sorted.forEach((item, idx) => {
      const newOrder = (idx + 1) * 10;
      if (item.kind === "tool") {
        const tool = tools.find((t) => t.id === item.id);
        if (tool) updatedTools.push({ ...tool, sortOrder: newOrder });
      } else {
        const feature = features.find((f) => f.id === item.id);
        if (feature) updatedFeatures.push({ ...feature, sortOrder: newOrder });
      }
    });

    if (updatedTools.length > 0) {
      setTools((prev) =>
        prev.map((t) => {
          const updated = updatedTools.find((u) => u.id === t.id);
          return updated ?? t;
        }),
      );
      await saveToolbarTools(
        tools.map((t) => {
          const updated = updatedTools.find((u) => u.id === t.id);
          return updated ?? t;
        }),
      );
    }

    for (const f of updatedFeatures) {
      await saveAiFeature(f);
    }
    if (updatedFeatures.length > 0) {
      setFeatures((prev) =>
        prev.map((f) => {
          const updated = updatedFeatures.find((u) => u.id === f.id);
          return updated ?? f;
        }),
      );
    }

    await notifyChanged();
  }

  function handleDragStart(idx: number) {
    setDragIndex(idx);
    setDropIndex(null);
  }

  function handleDragOver(idx: number) {
    if (dragIndex === null || dragIndex === idx) return;
    setDropIndex(idx);
  }

  function handleDragEnd() {
    if (dragIndex !== null && dropIndex !== null && dragIndex !== dropIndex) {
      void applyReorder(dragIndex, dropIndex);
    }
    setDragIndex(null);
    setDropIndex(null);
  }

  // Touch support
  function handleTouchStart(idx: number) {
    setDragIndex(idx);
  }

  function handleTouchMove(e: React.TouchEvent) {
    if (dragIndex === null || !listRef.current) return;
    const touch = e.touches[0];
    const elements = listRef.current.querySelectorAll("[data-toolbar-item]");
    for (let i = 0; i < elements.length; i++) {
      const rect = elements[i].getBoundingClientRect();
      if (touch.clientY >= rect.top && touch.clientY <= rect.bottom) {
        if (i !== dropIndex) setDropIndex(i);
        break;
      }
    }
  }

  function handleTouchEnd() {
    handleDragEnd();
  }

  return (
    <div className="grid h-full min-h-0 gap-3 overflow-hidden">
      {/* Toolbar Preview */}
      <Card className="grid content-start gap-3">
        <div>
          <h2 className="text-lg font-semibold">Toolbar Preview</h2>
          <p className="text-sm text-muted">
            {enabledItems.length} items shown on selection
          </p>
        </div>

        <div className="inline-flex items-center gap-1.5 rounded-lg border border-border bg-background p-2">
          {enabledItems.map((item) => (
            <div
              className="flex h-8 w-8 items-center justify-center rounded-md bg-surface text-strong transition hover:bg-surfaceHover"
              key={item.id}
              title={item.name}
            >
              <FeatureIcon icon={item.icon} size={16} />
            </div>
          ))}
          {enabledItems.length === 0 && (
            <p className="px-2 text-sm text-muted">No items enabled</p>
          )}
        </div>
      </Card>

      {/* Item List with drag-and-drop */}
      <Card className="grid min-h-0 content-start gap-2.5 overflow-y-auto">
        <h3 className="text-sm font-semibold text-muted">All Items</h3>

        <div ref={listRef} className="grid gap-1.5">
          {allItems.map((item, idx) => (
            <div
              data-toolbar-item={idx}
              className={`flex items-center gap-2.5 rounded-md border px-3 py-2.5 transition ${
                dragIndex === idx
                  ? "border-accent bg-accent/10 opacity-60"
                  : dropIndex === idx
                    ? "border-accent bg-accent/5"
                    : "border-border bg-surface hover:bg-surfaceHover"
              }`}
              draggable
              key={item.id}
              onDragOver={(e) => {
                e.preventDefault();
                handleDragOver(idx);
              }}
              onDragStart={() => handleDragStart(idx)}
              onDragEnd={handleDragEnd}
              onTouchStart={() => handleTouchStart(idx)}
              onTouchMove={handleTouchMove}
              onTouchEnd={handleTouchEnd}
            >
              {/* Drag handle */}
              <div className="cursor-grab text-muted active:cursor-grabbing">
                <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
                  <circle cx="4" cy="2" r="1.2" />
                  <circle cx="8" cy="2" r="1.2" />
                  <circle cx="4" cy="6" r="1.2" />
                  <circle cx="8" cy="6" r="1.2" />
                  <circle cx="4" cy="10" r="1.2" />
                  <circle cx="8" cy="10" r="1.2" />
                </svg>
              </div>

              <FeatureIcon icon={item.icon} size={16} />

              <div className="min-w-0 flex-1">
                <span className="text-sm font-medium text-strong">{item.name}</span>
                <span className="ml-2 text-xs text-muted">
                  {item.kind === "tool" ? TOOL_DESCRIPTIONS[item.id] ?? "Tool" : "AI feature"}
                </span>
              </div>

              <button
                className={`relative h-5 w-9 rounded-full transition-colors ${
                  item.enabled ? "bg-accent" : "bg-border"
                }`}
                onClick={() => void toggleItem(item)}
                type="button"
              >
                <span
                  className={`absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition-transform ${
                    item.enabled ? "translate-x-4" : "translate-x-0.5"
                  }`}
                />
              </button>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );
}

async function notifyChanged() {
  if (isTauriRuntime()) {
    await emit("englist://features-changed");
  }
}
