import { Sun, Moon, Check } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { AccentColor, AppSettings, BackgroundStyle, DockMode } from "../types";
import { applyAppearanceSettings, normalizedOpacity } from "../lib/appearance";
import { saveSettings } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { isTauriRuntime } from "../lib/platform";
import { Field, Input, Select, SettingsCard, FieldDivider, Textarea } from "../components/ui/Field";
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
    <div className="mx-auto max-w-2xl space-y-5">
      <header className="flex items-center justify-between">
        <h2 className="text-xl font-semibold tracking-tight">Settings</h2>
        <span className="text-xs text-muted">
          {saveState === "saving" ? "Saving…" : "Autosaved"}
        </span>
      </header>

      <SettingsCard title="Appearance" description="Theme, accent color and popup background.">
        <Field label="Theme" inline>
          <div className="flex gap-0.5 rounded-lg bg-surface/60 p-0.5">
            <ThemeButton
              active={draft.theme === "dark"}
              icon={<Moon size={14} />}
              label="Dark"
              onClick={() => setDraft({ ...draft, theme: "dark" })}
            />
            <ThemeButton
              active={draft.theme === "light"}
              icon={<Sun size={14} />}
              label="Light"
              onClick={() => setDraft({ ...draft, theme: "light" })}
            />
          </div>
        </Field>
        <FieldDivider />
        <Field label="Accent color" inline>
          <div className="flex items-center gap-2">
            {ACCENT_OPTIONS.map(({ value, color }) => (
              <AccentSwatch
                active={draft.accentColor === value}
                color={color}
                key={value}
                onClick={() => setDraft({ ...draft, accentColor: value })}
                title={value}
              />
            ))}
            <label
              className="relative flex h-7 w-7 items-center justify-center rounded-full border-2 transition hover:scale-105"
              style={{
                borderColor: isCustomActive ? "rgb(var(--color-strong))" : "transparent",
                backgroundColor: isCustomActive ? draft.customAccentColor : "rgb(var(--color-surface-hover))",
              }}
              title="Custom color"
            >
              {!isCustomActive && <span className="text-xs leading-none text-muted">+</span>}
              <input
                className="absolute inset-0 cursor-pointer opacity-0"
                onChange={(event) => setDraft({ ...draft, accentColor: "custom", customAccentColor: event.target.value })}
                type="color"
                value={draft.customAccentColor}
              />
            </label>
          </div>
        </Field>
        <FieldDivider />
        <Field label="Popup background" inline hint="Applied to the translation popup and bar.">
          <Select
            onChange={(event) => setDraft({ ...draft, backgroundStyle: event.target.value as BackgroundStyle })}
            value={draft.backgroundStyle}
          >
            <option value="solid">Solid</option>
            <option value="transparent">Transparent</option>
            <option value="macos_glass_clear">Liquid Glass</option>
          </Select>
        </Field>
        <FieldDivider />
        <Field label="Popup opacity" inline hint={`${normalizedOpacity(draft.windowOpacity)}%`}>
          <input
            className="h-1.5 w-40 cursor-pointer appearance-none rounded-full bg-surface-hover accent-accent"
            max={100}
            min={0}
            onChange={(event) => setDraft({ ...draft, windowOpacity: Number(event.target.value) })}
            step={5}
            type="range"
            value={normalizedOpacity(draft.windowOpacity)}
          />
        </Field>
      </SettingsCard>

      <SettingsCard title="Popup" description="Global shortcut and where the popup can appear.">
        <Field label="Show popup shortcut" inline hint="Works from any Space.">
          <ShortcutRecorder
            value={draft.popupShortcut}
            onChange={(shortcut) => setDraft({ ...draft, popupShortcut: shortcut })}
          />
        </Field>
      </SettingsCard>

      <SettingsCard title="General" description="App presence and system integration.">
        <Field label="App location" inline hint="Menu bar only hides the Dock icon.">
          <Select
            onChange={(event) => setDraft({ ...draft, dockMode: event.target.value as DockMode })}
            value={draft.dockMode}
          >
            <option value="dock_and_menu_bar">Dock and menu bar</option>
            <option value="menu_bar_only">Menu bar only</option>
          </Select>
        </Field>
        <FieldDivider />
        <Field label="Launch at login" inline hint="Start Lexi automatically when you log in.">
          <ToggleSwitch
            checked={draft.autoStart}
            onChange={(v) => setDraft({ ...draft, autoStart: v })}
          />
        </Field>
        <FieldDivider />
        <Field label="Excluded apps" hint="Bundle IDs of apps where the selection toolbar should not appear (e.g. com.apple.finder). One per line.">
          <Textarea
            className="font-mono text-xs"
            onChange={(event) => {
              const apps = event.target.value.split("\n").map((s) => s.trim()).filter(Boolean);
              setDraft({ ...draft, excludedToolbarApps: apps });
            }}
            placeholder="com.apple.finder"
            value={(draft.excludedToolbarApps ?? []).join("\n")}
          />
        </Field>
      </SettingsCard>

      <SettingsCard title="AI API" description="OpenAI-compatible endpoint used by all features.">
        <div className="grid gap-3">
          <Field label="Base URL">
            <Input
              onChange={(event) => setDraft({ ...draft, apiBaseUrl: event.target.value })}
              value={draft.apiBaseUrl}
            />
          </Field>
          <Field label="Model">
            <Input onChange={(event) => setDraft({ ...draft, model: event.target.value })} value={draft.model} />
          </Field>
          <Field
            label="API key"
            hint={savedApiKeyLength > 0 ? `Saved key: ${savedApiKeyLength} characters` : "Not saved yet"}
          >
            <Input
              onChange={(event) => setDraft({ ...draft, apiKey: event.target.value })}
              type="password"
              value={draft.apiKey}
            />
          </Field>
        </div>
      </SettingsCard>

      <div className="flex flex-col gap-2.5 pb-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-base font-semibold">About</h2>
          <p className="mt-1 text-sm text-muted">
            Lexi 0.1.0 · {isTauriRuntime() ? "Desktop (SQLite)" : "Browser preview (localStorage)"}
          </p>
        </div>
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
      className={`flex items-center justify-center gap-1.5 rounded-md px-3 py-1.5 text-sm font-medium transition ${
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

function AccentSwatch({
  active,
  color,
  onClick,
  title,
}: {
  active: boolean;
  color: string;
  onClick: () => void;
  title: string;
}) {
  return (
    <button
      className={`flex h-7 w-7 items-center justify-center rounded-full border-2 transition hover:scale-105 ${
        active ? "scale-110 border-strong" : "border-transparent"
      }`}
      onClick={onClick}
      style={{ backgroundColor: color }}
      title={title}
      type="button"
    >
      {active && <Check size={13} strokeWidth={3} className="text-white drop-shadow" />}
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

      if (event.key === "Escape") {
        setRecording(false);
        return;
      }

      const isBareModifier = ["Meta", "Control", "Shift", "Alt"].includes(event.key);

      if (isBareModifier) {
        const modifierName = event.key === "Control" ? "Ctrl"
          : event.key === "Meta" ? "Cmd"
          : event.key === "Shift" ? "Shift"
          : "Alt";
        const now = Date.now();
        const last = lastModifierRef.current;

        if (last && last.key === modifierName && now - last.time < 500) {
          onChange(`${modifierName}+${modifierName}`);
          lastModifierRef.current = null;
          setRecording(false);
          return;
        }

        lastModifierRef.current = { key: modifierName, time: now };
        return;
      }

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
      className={`min-w-28 rounded-md border px-2.5 py-1.5 text-center font-mono text-xs transition outline-none ${
        recording
          ? "border-accent bg-accent/10 text-accent"
          : "border-border bg-input text-strong focus:border-accent"
      }`}
      onClick={() => setRecording(true)}
      onBlur={() => setRecording(false)}
      type="button"
    >
      {recording ? "Recording…" : value || "Not set"}
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
      style={{ width: 38, height: 22 }}
      type="button"
      role="switch"
      aria-checked={checked}
    >
      <span
        className={`absolute rounded-full bg-white shadow-sm transition-all ${
          checked ? "right-[3px]" : "left-[3px]"
        }`}
        style={{ width: 16, height: 16, top: 3 }}
      />
    </button>
  );
}
