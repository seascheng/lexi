import { emit } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { LogicalPosition, PhysicalPosition } from "@tauri-apps/api/dpi";
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import type { AppSettings, DisplayMode, TranslationResult } from "../types";
import { loadPopupPosition } from "./database";
import { isTauriRuntime } from "./platform";

interface TranslateRequest {
  text: string;
  api_base_url: string;
  api_key: string;
  model: string;
  target_language: string;
  prompt_template: string;
}

export async function captureSelectedText() {
  if (!isTauriRuntime()) return "";
  return invoke<string>("get_selected_text");
}

export async function translateText(text: string, settings: AppSettings) {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Select or enter text to translate.");
  if (!settings.apiKey.trim()) {
    throw new Error("API key is not saved. Open Settings, enter the key, then click Save settings.");
  }
  if (!settings.apiBaseUrl.trim()) {
    throw new Error("API base URL is not saved.");
  }
  if (!settings.model.trim()) {
    throw new Error("Model is not saved.");
  }

  if (!isTauriRuntime()) return browserTranslation(trimmed, settings.targetLanguage);

  const request: TranslateRequest = {
    text: trimmed,
    api_base_url: settings.apiBaseUrl,
    api_key: settings.apiKey,
    model: settings.model,
    target_language: settings.targetLanguage,
    prompt_template: settings.promptTemplate,
  };

  return invoke<TranslationResult>("translate_text", { request });
}

export async function showTranslationLoading(text: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://translation-loading", { text, mode });
  await showTranslationWindow(mode);
}

export async function showTranslationRequest(text: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await showTranslationWindow(mode);
  await emit("englist://translation-request", { text, mode });
}

export async function showTranslationDisplay(result: TranslationResult, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://translation-ready", { result, mode });
  await showTranslationWindow(mode);
}

export async function showTranslationError(message: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://translation-error", { message, mode });
  await showTranslationWindow(mode);
}

async function showTranslationWindow(mode: DisplayMode) {
  const windowLabel = mode === "popup_card" ? "popup_card" : "float_bar";
  const targetWindow = await WebviewWindow.getByLabel(windowLabel);

  if (!targetWindow) return;

  if (mode === "popup_card") {
    const savedPosition = await loadPopupPosition();
    if (savedPosition) {
      await targetWindow.setPosition(new PhysicalPosition(savedPosition.x, savedPosition.y));
    } else {
      const position = await invoke<{ x: number; y: number }>("cursor_position");
      await targetWindow.setPosition(new LogicalPosition(position.x + 16, position.y + 18));
    }
  }

  await targetWindow.show();
  await targetWindow.setFocus();
}

export async function copyTranslation(result: TranslationResult) {
  const text = `${result.word} - ${result.translation}\n${result.definition}\n${result.example}`;

  if (isTauriRuntime()) {
    await writeText(text);
    return;
  }

  await navigator.clipboard.writeText(text);
}

function browserTranslation(text: string, targetLanguage: string): TranslationResult {
  return {
    word: text,
    translation: targetLanguage.toLowerCase().includes("chinese") ? "配置 API 后显示翻译" : "Configure API to translate",
    pos: "phrase",
    definition: "A local preview result shown when the Tauri backend or API key is unavailable.",
    example: `Use "${text}" in a sentence after configuring your OpenAI-compatible API.`,
  };
}
