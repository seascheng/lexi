import { emit } from "@tauri-apps/api/event";
import { Eye, EyeOff, Plus, Save, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { AiFeature, AiFeatureIcon } from "../types";
import { DEFAULT_CUSTOM_PROMPT_TEMPLATE } from "../lib/defaults";
import { deleteAiFeature, listAiFeatures, saveAiFeature } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { FEATURE_ICON_OPTIONS, FeatureIcon, isFeatureIcon } from "../lib/featureIcons";
import { isTauriRuntime } from "../lib/platform";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { Field, Input, Select, Textarea } from "../components/ui/Field";

export function FeaturesPage() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [draft, setDraft] = useState<AiFeature | null>(null);
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const activeFeature = useMemo(
    () => features.find((feature) => feature.id === draft?.id),
    [draft?.id, features],
  );

  useEffect(() => {
    void refreshFeatures();
  }, []);

  async function refreshFeatures() {
    const nextFeatures = await listAiFeatures();
    setFeatures(nextFeatures);
    setDraft((currentDraft) => currentDraft ?? nextFeatures[0] ?? null);
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
    setDraft(feature);
  }

  async function saveDraft() {
    if (!draft) return;

    setStatus("Saving...");
    setError("");
    try {
      await saveAiFeature(draft);
      await refreshFeatures();
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
      setDraft(nextFeatures[0] ?? null);
      await notifyFeaturesChanged();
      setStatus("Deleted");
    } catch (deleteError) {
      setError(errorMessage(deleteError, "Feature was not deleted."));
      setStatus("");
    }
  }

  function updateDraft(update: Partial<AiFeature>) {
    setDraft((currentDraft) => (currentDraft ? { ...currentDraft, ...update } : currentDraft));
    setStatus("");
  }

  return (
    <div className="grid h-full min-h-0 gap-3 overflow-hidden lg:grid-cols-[260px_1fr]">
      <Card className="grid h-full min-h-0 content-start gap-2.5 overflow-y-auto">
        <div className="flex items-center justify-between gap-2.5">
          <div>
            <h2 className="text-lg font-semibold">AI Features</h2>
            <p className="text-sm text-muted">{features.filter((feature) => feature.enabled).length} enabled</p>
          </div>
          <Button aria-label="New feature" onClick={createFeature} icon={<Plus size={16} />} />
        </div>

        <div className="grid gap-1.5">
          {features.map((feature) => (
            <button
              className={`rounded-md border px-2.5 py-2 text-left transition ${
                draft?.id === feature.id ? "border-accent bg-accent/10" : "border-border bg-surface hover:bg-surfaceHover"
              }`}
              key={feature.id}
              onClick={() => setDraft(feature)}
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
      </Card>

      <Card className="grid h-full min-h-0 content-start gap-3 overflow-y-auto">
        {draft ? (
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
                  onClick={() => updateDraft({ enabled: !draft.enabled })}
                  icon={draft.enabled ? <EyeOff size={16} /> : <Eye size={16} />}
                  variant={draft.enabled ? "secondary" : "primary"}
                >
                  {draft.enabled ? "Disable" : "Enable"}
                </Button>
                {draft.kind === "custom" ? (
                  <Button onClick={() => void removeFeature(draft)} variant="danger" icon={<Trash2 size={16} />}>
                    Delete
                  </Button>
                ) : null}
                <Button onClick={() => void saveDraft()} variant="primary" icon={<Save size={16} />}>
                  Save
                </Button>
              </div>
            </div>

            <div className="grid gap-2.5 md:grid-cols-2">
              <Field label="Name">
                <Input
                  disabled={draft.kind !== "custom"}
                  onChange={(event) => updateDraft({ name: event.target.value })}
                  value={draft.name}
                />
              </Field>
              <Field label="Sort order">
                <Input
                  onChange={(event) => updateDraft({ sortOrder: Number(event.target.value) })}
                  type="number"
                  value={draft.sortOrder}
                />
              </Field>
              <Field label="Icon" hint="Shown on the popup action button.">
                <Select
                  onChange={(event) => updateDraft({ icon: selectedFeatureIcon(event.target.value) })}
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
                    onChange={(event) => updateDraft({ targetLanguage: event.target.value })}
                    value={draft.targetLanguage}
                  />
                </Field>
              ) : null}
              {draft.kind === "review" ? (
                <Field label="Display interval" hint="Seconds between vocabulary cards in the popup.">
                  <Input
                    min={5}
                    onChange={(event) => updateDraft({ reviewIntervalSeconds: Number(event.target.value) })}
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
                onChange={(event) => updateDraft({ speechEnabled: event.target.checked })}
                type="checkbox"
              />
              Show speech button in the popup
            </label>

            {draft.kind === "translation" ? (
              <label className="flex items-center gap-3 text-sm text-strong">
                <input
                  checked={draft.autoSaveToVocabulary}
                  className="h-4 w-4 accent-[rgb(var(--color-accent))]"
                  onChange={(event) => updateDraft({ autoSaveToVocabulary: event.target.checked })}
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
                  onChange={(event) => updateDraft({ promptTemplate: event.target.value })}
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
        ) : (
          <div className="rounded-md border border-border bg-surface px-4 py-3 text-sm text-muted">
            Create a feature to start.
          </div>
        )}
      </Card>
    </div>
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
