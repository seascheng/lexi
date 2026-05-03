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
    setDraft((currentDraft) => currentDraft ?? { kind: "feature", data: nextFeatures[0] });
  }

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
    setDraft((current) => {
      if (current?.kind === "tool" && current.data.id === toolId) {
        return { ...current, data: { ...current.data, enabled: !current.data.enabled } };
      }
      return current;
    });
  }

  async function moveTool(toolId: string, direction: "up" | "down") {
    const sorted = [...tools].sort((a, b) => a.sortOrder - b.sortOrder);
    const idx = sorted.findIndex((t) => t.id === toolId);
    if (idx < 0) return;
    if (direction === "up" && idx === 0) return;
    if (direction === "down" && idx === sorted.length - 1) return;

    const nextTools = [...tools];
    const swapId = sorted[direction === "up" ? idx - 1 : idx + 1].id;
    const swapIdx = nextTools.findIndex((t) => t.id === swapId);
    const currentIdx = nextTools.findIndex((t) => t.id === toolId);
    const tmpOrder = nextTools[currentIdx].sortOrder;
    nextTools[currentIdx] = { ...nextTools[currentIdx], sortOrder: nextTools[swapIdx].sortOrder };
    nextTools[swapIdx] = { ...nextTools[swapIdx], sortOrder: tmpOrder };

    const resorted = nextTools.sort((a, b) => a.sortOrder - b.sortOrder);
    setTools(resorted);
    await saveToolbarTools(resorted);
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

  const allItems = useMemo(() => {
    const items: Array<{
      id: string;
      name: string;
      icon: AiFeatureIcon;
      enabled: boolean;
      sortOrder: number;
      kind: "tool" | "ai";
      label: string;
    }> = [
      ...tools.map((tool) => ({ id: tool.id, name: tool.name, icon: tool.icon, enabled: tool.enabled, sortOrder: tool.sortOrder, kind: "tool" as const, label: "Tool" })),
      ...features.map((f) => ({ id: f.id, name: f.name, icon: f.icon, enabled: f.enabled, sortOrder: f.sortOrder, kind: "ai" as const, label: featureLabel(f) })),
    ];
    return items.sort((a, b) => a.sortOrder - b.sortOrder);
  }, [tools, features]);

  const selectedDraftId =
    draft?.kind === "feature" ? draft.data.id : draft?.kind === "tool" ? draft.data.id : null;

  return (
    <div className="grid h-full min-h-0 gap-3 overflow-hidden lg:grid-cols-[260px_1fr]">
      <Card className="grid h-full min-h-0 content-start gap-2.5 overflow-y-auto">
        <div className="flex items-center justify-between gap-2.5">
          <div>
            <h2 className="text-lg font-semibold">Toolbar</h2>
            <p className="text-sm text-muted">{allItems.filter((item) => item.enabled).length} items shown</p>
          </div>
          <Button aria-label="New feature" onClick={createFeature} icon={<Plus size={16} />} />
        </div>

        <div className="grid gap-1.5">
          {allItems.map((item) => (
            <button
              className={`rounded-md border px-2.5 py-2 text-left transition ${
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
              <span className="flex min-w-0 items-center gap-2 text-sm font-medium text-strong">
                <FeatureIcon icon={item.icon} size={15} />
                <span className="truncate">{item.name}</span>
              </span>
              <span className="mt-1 block text-xs text-muted">
                {item.label}
                {item.enabled ? "" : " / disabled"}
              </span>
            </button>
          ))}
        </div>
      </Card>

      <Card className="grid h-full min-h-0 content-start gap-3 overflow-y-auto">
        {draft ? (
          draft.kind === "tool" ? (
            <ToolDetail
              tool={draft.data}
              tools={tools}
              onToggleEnabled={() => void toggleToolEnabled(draft.data.id)}
              onSortOrderChange={(value) => void updateToolSortOrder(draft.data.id, value)}
              onMoveUp={() => void moveTool(draft.data.id, "up")}
              onMoveDown={() => void moveTool(draft.data.id, "down")}
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
  onMoveUp: () => void;
  onMoveDown: () => void;
}) {
  const sorted = [...tools].sort((a, b) => a.sortOrder - b.sortOrder);
  const idx = sorted.findIndex((t) => t.id === tool.id);
  const canMoveUp = idx > 0;
  const canMoveDown = idx < sorted.length - 1;

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
            <Button onClick={onMoveUp} disabled={!canMoveUp} variant="ghost" icon={<ArrowUp size={16} />} />
            <Button onClick={onMoveDown} disabled={!canMoveDown} variant="ghost" icon={<ArrowDown size={16} />} />
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
