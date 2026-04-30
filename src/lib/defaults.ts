import type { AppSettings } from "../types";

export const DEFAULT_PROMPT_TEMPLATE = `You are a concise bilingual dictionary.
Translate the selected text to {{targetLanguage}} and return strict JSON only:
{
  "word": "original word or phrase",
  "translation": "target language translation",
  "pos": "part of speech",
  "definition": "brief English definition",
  "example": "natural English example sentence"
}

Selected text: {{text}}`;

export const DEFAULT_SETTINGS: AppSettings = {
  displayMode: "popup_card",
  theme: "dark",
  windowOpacity: 100,
  backgroundStyle: "macos_glass_clear",
  dockMode: "dock_and_menu_bar",
  shortcut: "CommandOrControl+Shift+T",
  apiBaseUrl: "https://api.openai.com/v1",
  apiKey: "",
  model: "gpt-4o-mini",
  targetLanguage: "Chinese",
  promptTemplate: DEFAULT_PROMPT_TEMPLATE,
  autoSave: true,
};
