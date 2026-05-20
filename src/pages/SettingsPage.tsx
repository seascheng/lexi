import { Sun, Moon } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { AccentColor, AppSettings, BackgroundStyle, DockMode } from "../types";
import { applyAppearanceSettings, normalizedOpacity } from "../lib/appearance";
import { saveSettings } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { isTauriRuntime } from "../lib/platform";
import { Field, Input, Select } from "../components/ui/Field";
import { enable as enableAutostart, disable as disableAutostart, isEnabled as isAutostartEnabled } from "@tauri-apps/plugin-autostart";

interface SettingsPageProps {
  settings: AppSettings;
  onSettingsChanged: (settings: AppSettings) => Promise<void>;
}

const ACCENT_OPTIONS: { value: AccentColor; color: string }[] = [
  { value: "default", color: "#8e8e93" },
  { value: "blue", color: "#3b82f6" },
  { value: "green", color: "#22c55e" },
  { value: "red", color: "#ef4444" },
  { value: "orange", color: "#f97316" },
  { value: "purple", color: "#a855f7" },
];

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

  // Sync autoStart with system autostart plugin
  const prevAutoStartRef = useRef(draft.autoStart);
  useEffect(() => {
    if (!isTauriRuntime()) return;
    if (prevAutoStartRef.current === draft.autoStart) return;
    prevAutoStartRef.current = draft.autoStart;

    if (draft.autoStart) {
      void enableAutostart().catch((e: unknown) => console.error("Failed to enable autostart", e));
    } else {
      void disableAutostart().catch((e: unknown) => console.error("Failed to disable autostart", e));
    }
  }, [draft.autoStart]);

  // On mount, sync autoStart setting with actual system state
  useEffect(() => {
    if (!isTauriRuntime()) return;
    void isAutostartEnabled().then((enabled: boolean) => {
      if (enabled !== draft.autoStart) {
        setDraft((d) => ({ ...d, autoStart: enabled }));
      }
    }).catch(() => {});
  }, []);

  const isCustomActive = draft.accentColor === "custom";

  return (
    <div className="space-y-4">
      <div className="space-y-2">
        <h2 className="text-base font-semibold">Appearance</h2>
        <div className="grid items-start gap-2 sm:grid-cols-2">
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
          <Field label="Accent color">
            <div className="flex items-center gap-1.5">
              {ACCENT_OPTIONS.map(({ value, color }) => (
                <button
                  key={value}
                  className={`h-6 w-6 rounded-full border-2 transition ${
                    draft.accentColor === value ? "border-strong scale-110" : "border-transparent hover:scale-105"
                  }`}
                  style={{ backgroundColor: color }}
                  onClick={() => setDraft({ ...draft, accentColor: value })}
                  title={value}
                  type="button"
                />
              ))}
              <label
                className={`relative flex h-6 w-6 items-center justify-center rounded-full border-2 transition ${
                  isCustomActive ? "border-strong scale-110" : "border-transparent hover:scale-105"
                }`}
                style={isCustomActive ? { backgroundColor: draft.customAccentColor } : undefined}
                title="Custom color"
              >
                {!isCustomActive && (
                  <span className="text-[10px] leading-none text-muted">+</span>
                )}
                <input
                  className="absolute inset-0 cursor-pointer opacity-0"
                  onChange={(event) => setDraft({ ...draft, accentColor: "custom", customAccentColor: event.target.value })}
                  type="color"
                  value={draft.customAccentColor}
                />
              </label>
            </div>
          </Field>
        </div>
      </div>
      <div className="space-y-2">
        <h3 className="text-sm font-medium text-muted">Popup window</h3>
        <div className="grid items-start gap-2 sm:grid-cols-2">
          <Field label="Background" hint="Applied only to the translation popup and bar.">
            <Select
              onChange={(event) => setDraft({ ...draft, backgroundStyle: event.target.value as BackgroundStyle })}
              value={draft.backgroundStyle}
            >
              <option value="solid">Solid</option>
              <option value="transparent">Transparent</option>
              <option value="macos_glass_clear">Liquid Glass</option>
            </Select>
          </Field>
          <Field label={`Opacity: ${normalizedOpacity(draft.windowOpacity)}%`}>
            <Input
              max={100}
              min={0}
              onChange={(event) => setDraft({ ...draft, windowOpacity: Number(event.target.value) })}
              step={5}
              type="range"
              value={normalizedOpacity(draft.windowOpacity)}
            />
          </Field>
          <Field label="Shortcut" hint="Global shortcut to show the popup from any Space.">
            <ShortcutRecorder
              value={draft.popupShortcut}
              onChange={(shortcut) => setDraft({ ...draft, popupShortcut: shortcut })}
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
          <Field label="Launch at login" hint="Automatically start Lexi when you log in.">
            <div className="flex items-center">
              <ToggleSwitch
                checked={draft.autoStart}
                onChange={(v) => setDraft({ ...draft, autoStart: v })}
              />
            </div>
          </Field>
          <Field label="Excluded apps" hint="Bundle IDs of apps where the toolbar should not appear (e.g. com.apple.finder). One per line.">
            <textarea
              className="h-20 w-full rounded-md border border-border bg-input px-2.5 py-1.5 text-sm text-strong outline-none focus:border-accent"
              onChange={(event) => {
                const apps = event.target.value.split("\n").map((s) => s.trim()).filter(Boolean);
                setDraft({ ...draft, excludedToolbarApps: apps });
              }}
              placeholder="com.apple.finder"
              value={(draft.excludedToolbarApps ?? []).join("\n")}
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
          <p className="mt-1 text-sm text-muted">Lexi 0.1.0</p>
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
  const lastModifierRef = useRef<{ key: string; time: number } | null>(null);

  useEffect(() => {
    if (!recording) {
      lastModifierRef.current = null;
      return;
    }

    function handleKeyDown(event: KeyboardEvent) {
      event.preventDefault();
      event.stopPropagation();

      // Escape stops recording
      if (event.key === "Escape") {
        setRecording(false);
        return;
      }

      // Detect bare modifier press — the key itself IS a modifier
      const isBareModifier = ["Meta", "Control", "Shift", "Alt"].includes(event.key);

      if (isBareModifier) {
        // Check for double-press of the same modifier within 500ms
        const modifierName = event.key === "Control" ? "Ctrl"
          : event.key === "Meta" ? "Cmd"
          : event.key === "Shift" ? "Shift"
          : "Alt";
        const now = Date.now();
        const last = lastModifierRef.current;

        if (last && last.key === modifierName && now - last.time < 500) {
          // Double-press detected
          onChange(`${modifierName}+${modifierName}`);
          lastModifierRef.current = null;
          setRecording(false);
          return;
        }

        lastModifierRef.current = { key: modifierName, time: now };
        return;
      }

      // Require at least one modifier for key combos
      if (!event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) {
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
