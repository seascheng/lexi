import { emit } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { LogicalPosition, LogicalSize } from "@tauri-apps/api/dpi";
import { WebviewWindow } from "@tauri-apps/api/webviewWindow";
import type { AiFeature, AiRunResult } from "../types";
import { isTauriRuntime } from "./platform";

const DEFAULT_POPUP_SIZE = 360;

export async function showAiLoading(text: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("lexi://ai-loading", { text, featureId: "translation" });
}

export async function showAiResult(result: AiRunResult, feature: AiFeature, text: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("lexi://ai-ready", { result, feature, text });
}

export async function showAiError(message: string) {
  if (!isTauriRuntime()) return;

  await showAiWindow();
  await emit("lexi://ai-error", { message, featureId: "translation" });
}

async function showAiWindow() {
  const windowLabel = "popup_card";
  const targetWindow = await WebviewWindow.getByLabel(windowLabel);

  if (!targetWindow) return;

  // Skip if native code already positioned and showed the window
  if (await targetWindow.isVisible()) return;

  await targetWindow.setSize(new LogicalSize(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE));

  const position = await invoke<{ x: number; y: number }>("popup_position", { popupHeight: DEFAULT_POPUP_SIZE });
  await targetWindow.setPosition(new LogicalPosition(position.x, position.y));

  await targetWindow.show();
  await targetWindow.setFocus();
  await emit("lexi://popup-shown", {});
}
