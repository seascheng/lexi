import { Sun, Moon } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { AppSettings, BackgroundStyle, DisplayMode, DockMode } from "../types";
import { applyAppearanceSettings, normalizedOpacity } from "../lib/appearance";
import { saveSettings } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { isTauriRuntime } from "../lib/platform";
import { Card } from "../components/ui/Card";
import { Field, Input, Select } from "../components/ui/Field";

interface SettingsPageProps {
  settings: AppSettings;
  onSettingsChanged: (settings: AppSettings) => Promise<void>;
}

export function SettingsPage({ settings, onSettingsChanged }: SettingsPageProps) {
  const [draft, setDraft] = useState(settings);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved">("idle");
  const [saveError, setSaveError] = useState("");
  const [savedApiKeyLength, setSavedApiKeyLength] = useState(settings.apiKey.length);
  const didMountRef = useRef(false);

  useEffect(() => {
    setDraft(settings);
    setSavedApiKeyLength(settings.apiKey.length);
  }, [settings]);

  useEffect(() => {
    void applyAppearanceSettings(draft, { applySystemControls: false }).catch((error) => {
      console.error("Failed to preview appearance settings", error);
    });

    void onSettingsChanged(draft);

    if (!didMountRef.current) {
      didMountRef.current = true;
      return;
    }

    setSaveState("saving");
    setSaveError("");

    const timeoutId = window.setTimeout(async () => {
      const nextDraft = {
        ...draft,
        windowOpacity: normalizedOpacity(draft.windowOpacity),
      };
      try {
        await saveSettings(nextDraft);
        setSavedApiKeyLength(nextDraft.apiKey.length);
        setSaveState("saved");
      } catch (error) {
        setSaveError(errorMessage(error, "Settings were not saved."));
        setSaveState("idle");
      }
    }, 350);

    return () => window.clearTimeout(timeoutId);
  }, [draft, onSettingsChanged]);

  return (
    <div className="grid gap-2.5">
      <Card className="grid gap-2.5">
        <h2 className="text-base font-semibold">Appearance</h2>
        <div className="grid gap-2.5 sm:grid-cols-2 lg:grid-cols-3">
          <Field label="Theme">
            <div className="grid grid-cols-2 gap-1 rounded-md border border-border bg-surface p-1">
              <ThemeButton
                active={draft.theme === "dark"}
                icon={<Moon size={16} />}
                label="Dark"
                onClick={() => setDraft({ ...draft, theme: "dark" })}
              />
              <ThemeButton
                active={draft.theme === "light"}
                icon={<Sun size={16} />}
                label="Light"
                onClick={() => setDraft({ ...draft, theme: "light" })}
              />
            </div>
          </Field>
          <Field label="Display mode">
            <Select
              onChange={(event) => setDraft({ ...draft, displayMode: event.target.value as DisplayMode })}
              value={draft.displayMode}
            >
              <option value="always_bar">Always-on bar</option>
              <option value="auto_bar">Auto-hide bar</option>
              <option value="popup_card">Popup card</option>
            </Select>
          </Field>
          <Field label="Popup background" hint="Applied only to the translation popup and bar.">
            <Select
              onChange={(event) => setDraft({ ...draft, backgroundStyle: event.target.value as BackgroundStyle })}
              value={draft.backgroundStyle}
            >
              <option value="solid">Solid</option>
              <option value="transparent">Transparent</option>
              <option value="macos_glass_clear">Liquid Glass</option>
            </Select>
          </Field>
          <Field label={`Popup opacity: ${normalizedOpacity(draft.windowOpacity)}%`}>
            <Input
              max={100}
              min={0}
              onChange={(event) => setDraft({ ...draft, windowOpacity: Number(event.target.value) })}
              step={5}
              type="range"
              value={normalizedOpacity(draft.windowOpacity)}
            />
          </Field>
          <Field label="App location" hint="Menu bar only hides the Dock icon.">
            <Select
              onChange={(event) => setDraft({ ...draft, dockMode: event.target.value as DockMode })}
              value={draft.dockMode}
            >
              <option value="dock_and_menu_bar">Dock and menu bar</option>
              <option value="menu_bar_only">Menu bar only</option>
            </Select>
          </Field>
        </div>
      </Card>

      <Card className="grid gap-2.5">
        <h2 className="text-base font-semibold">AI API</h2>
        <div className="grid gap-2.5">
          <Field label="Base URL">
            <Input
              onChange={(event) => setDraft({ ...draft, apiBaseUrl: event.target.value })}
              value={draft.apiBaseUrl}
            />
          </Field>
          <div className="grid gap-2.5 sm:grid-cols-2">
            <Field label="Model">
              <Input onChange={(event) => setDraft({ ...draft, model: event.target.value })} value={draft.model} />
            </Field>
            <Field label="API key">
              <Input
                onChange={(event) => setDraft({ ...draft, apiKey: event.target.value })}
                type="password"
                value={draft.apiKey}
              />
            </Field>
          </div>
        </div>
        <div className="rounded-md border border-border bg-example px-2.5 py-1.5 text-xs leading-5 text-muted">
          Runtime: {isTauriRuntime() ? "Desktop app SQLite" : "Browser preview localStorage"}.
          Saved API key: {savedApiKeyLength > 0 ? `${savedApiKeyLength} characters` : "not saved"}.
        </div>
      </Card>

      <Card className="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-base font-semibold">About</h2>
          <p className="mt-1 text-sm text-muted">Lexicon 0.1.0</p>
        </div>
        <p className="text-sm text-muted">{saveState === "saving" ? "Saving..." : "Autosaved"}</p>
      </Card>
      {saveError ? (
        <div className="rounded-md border border-danger/40 bg-danger/10 px-3 py-2 text-sm text-danger">
          {saveError}
        </div>
      ) : null}
    </div>
  );
}

interface ThemeButtonProps {
  active: boolean;
  icon: JSX.Element;
  label: string;
  onClick: () => void;
}

function ThemeButton({ active, icon, label, onClick }: ThemeButtonProps) {
  return (
    <button
      className={`inline-flex h-8 items-center justify-center gap-1.5 rounded-md text-sm font-medium transition ${
        active ? "bg-panel text-strong shadow-sm" : "text-muted hover:bg-panel hover:text-strong"
      }`}
      onClick={onClick}
      type="button"
    >
      {icon}
      {label}
    </button>
  );
}
