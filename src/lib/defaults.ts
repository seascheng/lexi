import type { AiFeature, AppSettings, Panel, ToolbarTool } from "../types";

export const DEFAULT_PROMPT_TEMPLATE = `You are a concise bilingual dictionary.
Translate the selected text to {{targetLanguage}} and return Markdown only.
Use this exact structure:

### {{text}}

- **Word:** original word or phrase
- **Translation:** target language translation
- **Part of speech:** part of speech
- **Definition:** brief English definition
- **Example:** natural English example sentence

Selected text: {{text}}`;

export const DEFAULT_CUSTOM_PROMPT_TEMPLATE = `Process the following text according to the feature name.

Text: {{text}}`;

export const DEFAULT_TRANSLATION_FEATURE: AiFeature = {
  id: "translation",
  name: "Translate",
  kind: "translation",
  promptTemplate: DEFAULT_PROMPT_TEMPLATE,
  outputMode: "plain_text",
  enabled: true,
  sortOrder: 0,
  panelEnabled: true,
  panelSortOrder: 0,
  autoSaveToVocabulary: true,
  targetLanguage: "Chinese",
  speechEnabled: true,
  icon: "languages",
};

export const DEFAULT_PANELS: Panel[] = [
  { id: "translate", name: "Translate", icon: "languages", enabled: true, sortOrder: 0 },
  { id: "review", name: "Review", icon: "book-open", enabled: true, sortOrder: 1 },
];

export const DEFAULT_SETTINGS: AppSettings = {
  theme: "dark",
  windowOpacity: 100,
  backgroundStyle: "macos_glass_clear",
  dockMode: "dock_and_menu_bar",
  toolbarEnabled: true,
  activePanelId: null,
  apiBaseUrl: "https://api.openai.com/v1",
  apiKey: "",
  model: "gpt-4o-mini",
};

export const TOOL_DESCRIPTIONS: Record<string, string> = {
  copy: "Copy selected text to clipboard.",
  search: "Search selected text in Google.",
  read: "Read selected text aloud.",
};

export const DEFAULT_TOOLS: ToolbarTool[] = [
  { id: "copy", name: "Copy", description: TOOL_DESCRIPTIONS.copy, icon: "clipboard", enabled: true, sortOrder: 100, panelEnabled: true, panelSortOrder: 100, config: {} },
  { id: "search", name: "Search", description: TOOL_DESCRIPTIONS.search, icon: "search", enabled: true, sortOrder: 110, panelEnabled: true, panelSortOrder: 110, config: { engine: "google" } },
  { id: "read", name: "Read", description: TOOL_DESCRIPTIONS.read, icon: "volume", enabled: true, sortOrder: 120, panelEnabled: true, panelSortOrder: 120, config: { engine: "system" } },
];
