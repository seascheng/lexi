import { emit } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { LogicalPosition, LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";
import type { AiFeature, AiRunResult, DisplayMode } from "../types";
import { loadPopupPosition, loadPopupSize } from "./database";
import { isTauriRuntime } from "./platform";

export async function captureSelectedText() {
  if (!isTauriRuntime()) return "";
  return invoke<string>("get_selected_text");
}

export async function showAiLoading(text: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://ai-loading", { text, mode, featureId: "translation" });
  await showAiWindow(mode);
}

export async function showAiRequest(text: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await showAiWindow(mode);
  await emit("englist://ai-request", { text, mode, featureId: "translation" });
}

export async function showAiResult(result: AiRunResult, feature: AiFeature, text: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://ai-ready", { result, feature, text, mode });
  await showAiWindow(mode);
}

export async function showAiError(message: string, mode: DisplayMode) {
  if (!isTauriRuntime()) return;

  await emit("englist://ai-error", { message, mode, featureId: "translation" });
  await showAiWindow(mode);
}

async function showAiWindow(mode: DisplayMode) {
  const windowLabel = mode === "popup_card" ? "popup_card" : "float_bar";
  const targetWindow = await WebviewWindow.getByLabel(windowLabel);

  if (!targetWindow) return;

  if (mode === "popup_card") {
    const [savedPosition, savedSize] = await Promise.all([loadPopupPosition(), loadPopupSize()]);
    if (savedSize) {
      await targetWindow.setSize(new LogicalSize(savedSize.width, savedSize.height));
    }

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
