import type { AiFeature, AppSettings } from "../types";

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
  autoSaveToVocabulary: true,
  targetLanguage: "Chinese",
  reviewIntervalSeconds: 30,
  speechEnabled: true,
  icon: "languages",
};

export const DEFAULT_REVIEW_FEATURE: AiFeature = {
  id: "review",
  name: "Review",
  kind: "review",
  promptTemplate: "",
  outputMode: "plain_text",
  enabled: true,
  sortOrder: 10,
  autoSaveToVocabulary: false,
  targetLanguage: "",
  reviewIntervalSeconds: 30,
  speechEnabled: true,
  icon: "book-plus",
};

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
};
