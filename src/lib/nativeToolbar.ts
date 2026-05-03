import { invoke } from "@tauri-apps/api/core";
import type { AiFeature, AiFeatureIcon, AppSettings, ToolbarTool } from "../types";
import { isTauriRuntime } from "./platform";

interface NativeToolbarAction {
  id: string;
  title: string;
  icon: string;
}

export async function syncNativeToolbar(
  settings: AppSettings,
  features: AiFeature[],
  tools: ToolbarTool[],
) {
  if (!isTauriRuntime()) return;

  const actions = settings.toolbarEnabled ? nativeToolbarActions(features, tools) : [];
  await invoke("configure_native_toolbar", {
    enabled: settings.toolbarEnabled,
    actions,
  }).catch((error) => {
    console.warn("Failed to sync native toolbar", error);
  });

  if (!settings.toolbarEnabled) {
    return;
  }
}

function nativeToolbarActions(features: AiFeature[], tools: ToolbarTool[]): NativeToolbarAction[] {
  const enabledFeatures = features.filter((feature) => feature.enabled);
  const enabledTools = tools.filter((tool) => tool.enabled);
  const items: Array<{ id: string; name: string; icon: AiFeatureIcon; sortOrder: number }> = [
    ...enabledTools.map((tool) => ({ id: tool.id, name: tool.name, icon: tool.icon, sortOrder: tool.sortOrder })),
    ...enabledFeatures.map((feature) => ({ id: feature.id, name: feature.name, icon: feature.icon, sortOrder: feature.sortOrder })),
  ].sort((a, b) => a.sortOrder - b.sortOrder);

  return items.map((item) => ({
    id: item.id,
    title: item.name,
    icon: item.icon,
  }));
}
