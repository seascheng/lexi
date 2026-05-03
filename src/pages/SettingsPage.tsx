import { Sun, Moon } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { AppSettings, BackgroundStyle, DockMode } from "../types";
import { applyAppearanceSettings, normalizedOpacity } from "../lib/appearance";
import { saveSettings } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { isTauriRuntime } from "../lib/platform";
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
    <div className="space-y-4">
      <div className="space-y-2">
        <h2 className="text-base font-semibold">Appearance</h2>
        <div className="grid items-start gap-2 sm:grid-cols-2 lg:grid-cols-3">
          <Field label="Theme">
            <div className="flex gap-0.5 rounded-md bg-surface/30 p-0.5">
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
          <Field label="Popup shortcut" hint="Global shortcut to show the popup from any Space.">
            <ShortcutRecorder
              value={draft.popupShortcut}
              onChange={(shortcut) => setDraft({ ...draft, popupShortcut: shortcut })}
            />
          </Field>
        </div>
      </div>
      <hr className="border-border/30" />
      <div className="space-y-2">
        <h2 className="text-base font-semibold">AI API</h2>
        <div className="grid gap-2">
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
        <div className="rounded-md bg-surface/50 px-3 py-1.5 text-xs leading-5 text-muted">
          Runtime: {isTauriRuntime() ? "Desktop app SQLite" : "Browser preview localStorage"}.
          Saved API key: {savedApiKeyLength > 0 ? `${savedApiKeyLength} characters` : "not saved"}.
        </div>
      </div>
      <hr className="border-border/30" />
      <div className="flex flex-col gap-2.5 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-base font-semibold">About</h2>
          <p className="mt-1 text-sm text-muted">Lexicon 0.1.0</p>
        </div>
        <p className="text-sm text-muted">{saveState === "saving" ? "Saving..." : "Autosaved"}</p>
      </div>
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
      className={`flex flex-1 items-center justify-center gap-1.5 rounded py-1.5 text-sm font-medium transition ${
        active ? "bg-panel text-strong shadow-sm" : "text-muted hover:text-strong"
      }`}
      onClick={onClick}
      type="button"
    >
      {icon}
      {label}
    </button>
  );
}

interface ShortcutRecorderProps {
  value: string;
  onChange: (value: string) => void;
}

function ShortcutRecorder({ value, onChange }: ShortcutRecorderProps) {
  const [recording, setRecording] = useState(false);

  useEffect(() => {
    if (!recording) return;

    function handleKeyDown(event: KeyboardEvent) {
      event.preventDefault();
      event.stopPropagation();

      // Ignore bare modifier presses
      if (["Meta", "Control", "Shift", "Alt"].includes(event.key)) return;

      // Require at least one modifier
      if (!event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
        if (event.key === "Escape") setRecording(false);
        return;
      }

      const parts: string[] = [];
      if (event.metaKey) parts.push("Cmd");
      if (event.ctrlKey) parts.push("Ctrl");
      if (event.shiftKey) parts.push("Shift");
      if (event.altKey) parts.push("Alt");

      const key = event.code.startsWith("Key")
        ? event.code.slice(3)
        : event.code.startsWith("Digit")
          ? event.code.slice(5)
          : event.code === "Space"
            ? "Space"
            : event.code === "Enter"
              ? "Enter"
              : event.key.length === 1
                ? event.key.toUpperCase()
                : null;

      if (key) {
        parts.push(key);
        onChange(parts.join("+"));
        setRecording(false);
      }
    }

    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, [recording, onChange]);

  return (
    <button
      className={`h-8 rounded-md border px-2.5 text-left text-sm transition outline-none ${
        recording
          ? "border-accent bg-accent/10 text-accent"
          : "border-border bg-input text-strong focus:border-accent"
      }`}
      onClick={() => setRecording(true)}
      onBlur={() => setRecording(false)}
      type="button"
    >
      {recording ? "Press shortcut..." : value || "Not set"}
    </button>
  );
}
