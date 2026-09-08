import { setDockVisibility, setTheme } from "@tauri-apps/api/app";
import { Effect, EffectState, getCurrentWindow } from "@tauri-apps/api/window";
import type { AppSettings } from "../types";
import { isTauriRuntime } from "./platform";

interface AppearanceOptions {
  applySystemControls?: boolean;
}

export async function applyAppearanceSettings(
  settings: AppSettings,
  { applySystemControls = true }: AppearanceOptions = {},
) {
  const theme = settings.theme === "light" ? "light" : "dark";
  const currentWindow = isTauriRuntime() ? getCurrentWindow() : null;

  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.accent = settings.accentColor || "default";
  document.documentElement.dataset.backgroundStyle = "solid";

  applyAccentColor(settings.accentColor, settings.customAccentColor);

  if (!isTauriRuntime()) return;

  await setTheme(theme);
  if (currentWindow) {
    await applyMainWindowVibrancy(currentWindow);
  }

  if (applySystemControls) {
    await setDockVisibility(settings.dockMode !== "menu_bar_only");
  }
}

export function normalizedOpacity(value: number) {
  if (!Number.isFinite(value)) return 100;
  return Math.min(100, Math.max(0, Math.round(value)));
}

async function applyMainWindowVibrancy(currentWindow: ReturnType<typeof getCurrentWindow>) {
  const transparent: [number, number, number, number] = [0, 0, 0, 0];

  try {
    await currentWindow.setEffects({
      effects: [Effect.WindowBackground],
      state: EffectState.Active,
      radius: 16,
    });
    await currentWindow.setBackgroundColor(transparent);
  } catch (error) {
    console.warn("Failed to apply main window vibrancy", error);
  }
}

function hexToRgb(hex: string): { r: number; g: number; b: number } | null {
  const match = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
  if (!match) return null;
  return { r: parseInt(match[1], 16), g: parseInt(match[2], 16), b: parseInt(match[3], 16) };
}

function applyAccentColor(accent: string, customHex: string) {
  const el = document.documentElement;

  if (accent !== "custom") {
    el.style.removeProperty("--color-accent");
    el.style.removeProperty("--color-accent-hover");
    el.style.removeProperty("--color-accent-foreground");
    return;
  }

  const rgb = hexToRgb(customHex);
  if (!rgb) return;

  const darken = (v: number) => Math.round(v * 0.82);
  el.style.setProperty("--color-accent", `${rgb.r} ${rgb.g} ${rgb.b}`);
  el.style.setProperty("--color-accent-hover", `${darken(rgb.r)} ${darken(rgb.g)} ${darken(rgb.b)}`);
  el.style.setProperty("--color-accent-foreground", "255 255 255");
}
