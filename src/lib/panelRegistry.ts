import type { ComponentType } from "react";
import type { WordEntry } from "../types";

export interface PanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

const registry = new Map<string, ComponentType<PanelProps>>();

export function registerPanel(id: string, component: ComponentType<PanelProps>): void {
  registry.set(id, component);
}

export function getPanelComponent(id: string): ComponentType<PanelProps> | undefined {
  return registry.get(id);
}
