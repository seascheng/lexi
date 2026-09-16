import { Sun, Moon, Check, Palette, PanelTop, Cog, Sparkles, Info } from "lucide-react";
import { useEffect, useRef, useState, type CSSProperties } from "react";
import type { AccentColor, AppSettings, BackgroundStyle, DockMode } from "../types";
import { applyAppearanceSettings, normalizedOpacity } from "../lib/appearance";
import { saveSettings } from "../lib/database";
import { errorMessage } from "../lib/errors";
import { isTauriRuntime } from "../lib/platform";
import { Field, Input, Select, SettingsCard, FieldDivider, Textarea, ToggleSwitch } from "../components/ui/Field";
import { cn } from "../lib/cn";
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

type Section = "appearance" | "popup" | "general" | "ai" | "about";

const SECTIONS: Array<{ id: Section; label: string; icon: JSX.Element }> = [
  { id: "appearance", label: "Appearance", icon: <Palette size={15} /> },
  { id: "popup", label: "Popup", icon: <PanelTop size={15} /> },
  { id: "general", label: "General", icon: <Cog size={15} /> },
  { id: "ai", label: "AI API", icon: <Sparkles size={15} /> },
  { id: "about", label: "About", icon: <Info size={15} /> },
];

export function SettingsPage({ settings, onSettingsChanged }: SettingsPageProps) {
  const [draft, setDraft] = useState(settings);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved">("idle");
  const [saveError, setSaveError] = useState("");
  const [savedApiKeyLength, setSavedApiKeyLength] = useState(settings.apiKey.length);
  const [section, setSection] = useState<Section>("appearance");
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
  const opacity = normalizedOpacity(draft.windowOpacity);

  return (
    <div className="flex min-h-full flex-col md:h-full">
      <div className="flex min-h-0 flex-1 flex-col md:flex-row">
        <nav className="flex shrink-0 gap-0.5 overflow-x-auto border-b border-border/30 p-2 md:w-[200px] md:flex-col md:overflow-visible md:border-b-0 md:border-r md:p-2.5">
          {SECTIONS.map(({ id, label, icon }) => {
            const active = section === id;
            return (
              <button
                aria-current={active ? "page" : undefined}
                className={cn(
                  "flex h-7 shrink-0 items-center gap-2 rounded-md px-2 text-[13px] font-medium transition-colors",
                  active
                    ? "bg-strong/10 text-strong"
                    : "text-muted hover:bg-strong/5 hover:text-strong",
                )}
                key={id}
                onClick={() => setSection(id)}
                type="button"
              >
                {icon}
                <span className="whitespace-nowrap">{label}</span>
              </button>
            );
          })}
        </nav>

        {/* Page host — one section at a time, scrolls on its own */}
        <div className="min-h-0 flex-1 md:overflow-y-auto">
          <div className="px-2 py-6 md:px-6">
            {section === "appearance" && (
              <SettingsCard title="Appearance" description="Theme, accent color and popup background.">
                <Field label="Theme" inline>
                  <div className="flex gap-0.5 rounded-md bg-surface/60 p-0.5">
                    <ThemeButton
                      active={draft.theme === "dark"}
                      icon={<Moon size={13} />}
                      label="Dark"
                      onClick={() => setDraft({ ...draft, theme: "dark" })}
                    />
                    <ThemeButton
                      active={draft.theme === "light"}
                      icon={<Sun size={13} />}
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
                <Field label="Popup opacity" inline hint={`${opacity}%`}>
                  <input
                    className="lexi-slider"
                    max={100}
                    min={0}
                    onChange={(event) => setDraft({ ...draft, windowOpacity: Number(event.target.value) })}
                    step={5}
                    style={{ "--slider-fill": `${opacity}%` } as CSSProperties}
                    type="range"
                    value={opacity}
                  />
                </Field>
              </SettingsCard>
            )}

            {section === "popup" && (
              <SettingsCard title="Popup" description="Global shortcut and where the popup can appear.">
                <Field label="Show popup shortcut" inline hint="Works from any Space.">
                  <ShortcutRecorder
                    value={draft.popupShortcut}
                    onChange={(shortcut) => setDraft({ ...draft, popupShortcut: shortcut })}
                  />
                </Field>
                <Field label="Show launcher shortcut" inline hint="Opens the launcher panel from any Space.">
                  <Select
                    value={draft.launcherShortcut}
                    onChange={(event) => setDraft({ ...draft, launcherShortcut: event.target.value })}
                  >
                    <option value="Shift+Shift">Double Shift</option>
                    <option value="Alt+Alt">Double Option</option>
                    <option value="Cmd+Cmd">Double Command</option>
                    <option value="Cmd+Shift+L">Cmd+Shift+L</option>
                  </Select>
                </Field>
              </SettingsCard>
            )}

            {section === "general" && (
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
            )}

            {section === "ai" && (
              <SettingsCard title="AI API" description="OpenAI-compatible endpoint used by all features.">
                <Field label="Base URL" inline>
                  <Input
                    className="w-72"
                    onChange={(event) => setDraft({ ...draft, apiBaseUrl: event.target.value })}
                    value={draft.apiBaseUrl}
                  />
                </Field>
                <FieldDivider />
                <Field label="Model" inline>
                  <Input
                    className="w-72"
                    onChange={(event) => setDraft({ ...draft, model: event.target.value })}
                    value={draft.model}
                  />
                </Field>
                <FieldDivider />
                <Field
                  label="API key"
                  inline
                  hint={savedApiKeyLength > 0 ? `Saved key: ${savedApiKeyLength} characters` : "Not saved yet"}
                >
                  <Input
                    className="w-72"
                    onChange={(event) => setDraft({ ...draft, apiKey: event.target.value })}
                    type="password"
                    value={draft.apiKey}
                  />
                </Field>
              </SettingsCard>
            )}

            {section === "about" && (
              <section className="mx-auto w-full max-w-[640px]">
                <header>
                  <h3 className="text-[15px] font-semibold tracking-tight text-strong">About</h3>
                  <p className="mt-1 text-xs leading-relaxed text-muted">Lexi — translate, collect, review.</p>
                </header>
                <div className="mt-3.5 rounded-xl border border-border/70 bg-panel shadow-sm">
                  <div className="px-4 pb-3.5 pt-3.5">
                    <div className="text-[11px] font-medium uppercase tracking-wide text-muted">Version</div>
                    <div className="mt-0.5 font-mono text-[13px] text-strong">0.1.0</div>
                  </div>
                  <div className="mx-4 border-t border-border/40" />
                  <div className="flex items-center gap-2 px-4 py-3.5">
                    <span className={cn("size-1.5 rounded-full", isTauriRuntime() ? "bg-emerald-500" : "bg-muted/60")} />
                    <span className="text-xs text-muted">
                      {isTauriRuntime() ? "Desktop build — data stored in SQLite." : "Browser preview — data stored in localStorage."}
                    </span>
                  </div>
                </div>
              </section>
            )}
          </div>
        </div>
      </div>

      {/* Status strip — goty's 26pt bottom bar */}
      <div className="mt-auto flex h-[26px] shrink-0 items-center justify-between gap-3 border-t border-border/30 px-3">
        <span className="truncate text-xs text-muted">Changes save automatically.</span>
        {saveError ? (
          <span className="truncate text-xs text-danger">{saveError}</span>
        ) : (
          <span className="flex shrink-0 items-center gap-1.5 text-xs text-muted">
            <span
              aria-hidden
              className={cn(
                "size-1.5 rounded-full",
                saveState === "saving" ? "bg-amber-500" : "bg-emerald-500",
              )}
            />
            {saveState === "saving" ? "Saving…" : "All changes saved"}
          </span>
        )}
      </div>
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
      className={cn(
        "flex h-[22px] items-center justify-center gap-1.5 rounded-md px-2.5 text-xs font-medium transition-colors",
        active ? "bg-panel text-strong shadow-sm" : "text-muted hover:text-strong",
      )}
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
      className={cn(
        "h-7 min-w-28 rounded-md border px-2.5 text-center font-mono text-xs transition outline-none",
        recording
          ? "border-strong/50 bg-strong/10 text-strong"
          : "border-border/70 bg-input text-strong hover:border-strong/40 focus:border-strong/50",
      )}
      onClick={() => setRecording(true)}
      onBlur={() => setRecording(false)}
      type="button"
    >
      {recording ? "Recording…" : value || "Not set"}
    </button>
  );
}
