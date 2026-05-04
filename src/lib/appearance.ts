import { setDockVisibility, setTheme } from "@tauri-apps/api/app";
import { Effect, EffectState, getCurrentWindow } from "@tauri-apps/api/window";
import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { GlassMaterialVariant, setLiquidGlassEffect } from "tauri-plugin-liquid-glass-api";
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
  const appliesToTranslationWindow = Boolean(
    currentWindow && (currentWindow.label === "popup_card" || currentWindow.label === "float_bar"),
  );
  const surfaceOpacity = appliesToTranslationWindow ? popupSurfaceOpacity(settings) : 1;

  document.documentElement.dataset.theme = theme;
  document.documentElement.dataset.accent = settings.accentColor || "default";
  document.documentElement.dataset.backgroundStyle = appliesToTranslationWindow ? settings.backgroundStyle : "solid";
  document.documentElement.style.setProperty("--app-surface-opacity", String(surfaceOpacity));

  applyAccentColor(settings.accentColor, settings.customAccentColor);

  if (!isTauriRuntime()) return;

  await setTheme(theme);
  if (appliesToTranslationWindow && currentWindow) {
    await clearTranslationWindowChrome(currentWindow);
    await applyTranslationWindowMaterial(settings);
  } else {
    await applyWindowEffects(settings, false, currentWindow);
  }

  if (applySystemControls) {
    await setDockVisibility(settings.dockMode !== "menu_bar_only");
  }
}

async function applyTranslationWindowMaterial(settings: AppSettings) {
  try {
    if (settings.backgroundStyle === "macos_glass_clear") {
      await setLiquidGlassEffect({
        cornerRadius: 22,
        tintColor: liquidGlassTint(settings),
        variant: GlassMaterialVariant.Clear,
      });
      return;
    }

    await setLiquidGlassEffect({ enabled: false });
    await applyWindowEffects(settings, false, getCurrentWindow());
  } catch (error) {
    console.warn("Failed to apply liquid glass effect", error);
    await applyWindowEffects(settings, true, getCurrentWindow());
  }
}

async function clearTranslationWindowChrome(currentWindow: ReturnType<typeof getCurrentWindow>) {
  const transparent: [number, number, number, number] = [0, 0, 0, 0];

  try {
    await currentWindow.setShadow(false);
    await currentWindow.setBackgroundColor(transparent);
    await getCurrentWebviewWindow().setBackgroundColor(transparent);
  } catch (error) {
    console.warn("Failed to clear translation window chrome", error);
  }
}

export function normalizedOpacity(value: number) {
  if (!Number.isFinite(value)) return 100;
  return Math.min(100, Math.max(0, Math.round(value)));
}

function popupSurfaceOpacity(settings: AppSettings) {
  if (settings.backgroundStyle === "solid" || settings.backgroundStyle === "macos_glass_clear") return 1;
  return normalizedOpacity(settings.windowOpacity) / 100;
}

function liquidGlassTint(settings: AppSettings) {
  const alpha = Math.round(normalizedOpacity(settings.windowOpacity) * 0.42);
  const clampedAlpha = Math.min(66, Math.max(14, alpha));
  const alphaHex = clampedAlpha.toString(16).padStart(2, "0");
  return settings.theme === "light" ? `#ffffff${alphaHex}` : `#1f1f1f${alphaHex}`;
}

async function applyWindowEffects(
  settings: AppSettings,
  appliesToTranslationWindow: boolean,
  currentWindow: ReturnType<typeof getCurrentWindow> | null,
) {
  if (!currentWindow) return;

  try {
    if (appliesToTranslationWindow && settings.backgroundStyle === "macos_glass_clear") {
      await currentWindow.setEffects({
        effects: [Effect.UnderWindowBackground, Effect.WindowBackground, Effect.ContentBackground],
        state: EffectState.Active,
        radius: 12,
      });
      return;
    }

    await currentWindow.clearEffects();
  } catch (error) {
    console.warn("Failed to apply window effects", error);
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
