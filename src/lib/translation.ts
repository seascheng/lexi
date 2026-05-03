import { emit } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { LogicalPosition, LogicalSize, PhysicalPosition } from "@tauri-apps/api/dpi";
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";
import type { AiFeature, AiRunResult } from "../types";
import { loadPopupPosition } from "./database";
import { isTauriRuntime } from "./platform";

const DEFAULT_POPUP_SIZE = 360;

export async function showAiLoading(text: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("englist://ai-loading", { text, featureId: "translation" });
}

export async function showAiResult(result: AiRunResult, feature: AiFeature, text: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("englist://ai-ready", { result, feature, text });
}

export async function showAiError(message: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("englist://ai-error", { message, featureId: "translation" });
}

async function showAiWindow() {
  const windowLabel = "popup_card";
  const targetWindow = await WebviewWindow.getByLabel(windowLabel);

  if (!targetWindow) return;

  const savedPosition = await loadPopupPosition();
  await targetWindow.setSize(new LogicalSize(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE));

  if (savedPosition) {
    await targetWindow.setPosition(new PhysicalPosition(savedPosition.x, savedPosition.y));
  } else {
    const position = await invoke<{ x: number; y: number }>("cursor_position");
    await targetWindow.setPosition(new LogicalPosition(position.x + 16, position.y + 18));
  }

  await targetWindow.show();
  await targetWindow.setSize(new LogicalSize(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE));
  await targetWindow.setFocus();
  await emit("englist://popup-shown", {});
}
