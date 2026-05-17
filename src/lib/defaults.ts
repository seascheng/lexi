import type { AiFeature, AppSettings, Panel, ToolbarTool } from "../types";

export const DEFAULT_PROMPT_TEMPLATE = `You are a concise bilingual (English ↔ Chinese) dictionary.
Translate the selected text and return Markdown only.

Input:
<<<TEXT>>>
{{text}}
<<<END>>>

1. If the input is an English word:
- Translate it into Chinese
- If helpful, analyze it using prefix/suffix
- Provide English example sentences for common usage

2. If the input is a sentence:
- Translate it into Chinese
- Analyze its sentence structure
- Identify common English patterns in it
- If helpful, use additional English examples to explain the pattern

Output:
- Return as a Markdown bullet list
- Keep it multi-line
- Do not add extra sections or labels beyond the above`;

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
  isBuiltin: true,
};

const EXTRACT_PROMPT_TEMPLATE = `Analyze text as ONE learning point.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>

Classify: word / phrase / sentence

- word/phrase: meaning + usage
- sentence: meaning + structure + pattern

Give 1 example. Keep concise.

Return Markdown:

### Learning point
- **Type:**
- **Meaning:**
- **Usage:**
- **Example:**
- **Note:**`;

export const DEFAULT_EXTRACT_FEATURE: AiFeature = {
  id: "extract",
  name: "Extract",
  kind: "custom",
  promptTemplate: EXTRACT_PROMPT_TEMPLATE,
  outputMode: "plain_text",
  enabled: true,
  sortOrder: 10,
  panelEnabled: true,
  panelSortOrder: 10,
  autoSaveToVocabulary: false,
  targetLanguage: "Chinese",
  speechEnabled: false,
  icon: "highlighter",
  isBuiltin: true,
};

const REWRITE_PROMPT_TEMPLATE = `Rewrite sentences into idiomatic English and flag issues.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>

For each sentence:
- rewrite naturally
- list unidiomatic parts
- brief reason

Return Markdown list:

- Improved: ...
- Issues:
  - ...
- Explanation:
  - ...`;

export const DEFAULT_REWRITE_FEATURE: AiFeature = {
  id: "rewrite",
  name: "Rewrite",
  kind: "custom",
  promptTemplate: REWRITE_PROMPT_TEMPLATE,
  outputMode: "plain_text",
  enabled: true,
  sortOrder: 40,
  panelEnabled: true,
  panelSortOrder: 40,
  autoSaveToVocabulary: false,
  targetLanguage: "Chinese",
  speechEnabled: false,
  icon: "wand",
  isBuiltin: true,
};

const AI_PROMPT_TEMPLATE = `Answer the questions in the following text or explain this concept in a popular, detailed, and organized manner.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>`;

export const DEFAULT_AI_FEATURE: AiFeature = {
  id: "ai",
  name: "AI",
  kind: "custom",
  promptTemplate: AI_PROMPT_TEMPLATE,
  outputMode: "plain_text",
  enabled: true,
  sortOrder: 60,
  panelEnabled: true,
  panelSortOrder: 60,
  autoSaveToVocabulary: false,
  targetLanguage: "Chinese",
  speechEnabled: false,
  icon: "sparkles",
  isBuiltin: true,
};

export const DEFAULT_PANELS: Panel[] = [
  { id: "translate", name: "Actions", icon: "file-text", enabled: true, sortOrder: 0 },
  { id: "notes", name: "Notes", icon: "notebook-pen", enabled: true, sortOrder: 1 },
  { id: "review", name: "Review", icon: "book-open", enabled: true, sortOrder: 2 },
];

export const DEFAULT_SETTINGS: AppSettings = {
  theme: "dark",
  accentColor: "default",
  customAccentColor: "#3b82f6",
  windowOpacity: 100,
  backgroundStyle: "macos_glass_clear",
  dockMode: "dock_and_menu_bar",
  toolbarEnabled: true,
  activePanelId: null,
  apiBaseUrl: "https://api.openai.com/v1",
  apiKey: "",
  model: "gpt-4o-mini",
  popupShortcut: "Cmd+Shift+T",
  autoStart: false,
};

export const TOOL_DESCRIPTIONS: Record<string, string> = {
  copy: "Copy selected text to clipboard.",
  search: "Search selected text in Google.",
  read: "Read selected text aloud.",
  note: "Save selected text as a note.",
  handoff: "Send selected text to an external AI app.",
};

export const DEFAULT_TOOLS: ToolbarTool[] = [
  { id: "copy", name: "Copy", description: TOOL_DESCRIPTIONS.copy, icon: "copy", enabled: true, sortOrder: 100, panelEnabled: true, panelSortOrder: 100, config: {} },
  { id: "search", name: "Search", description: TOOL_DESCRIPTIONS.search, icon: "search", enabled: true, sortOrder: 110, panelEnabled: true, panelSortOrder: 110, config: { engine: "google" } },
  { id: "read", name: "Read", description: TOOL_DESCRIPTIONS.read, icon: "volume", enabled: true, sortOrder: 120, panelEnabled: true, panelSortOrder: 120, config: { engine: "system" } },
  { id: "note", name: "Note", description: TOOL_DESCRIPTIONS.note, icon: "notebook-pen", enabled: true, sortOrder: 130, panelEnabled: true, panelSortOrder: 130, config: {} },
  { id: "handoff", name: "Handoff", description: TOOL_DESCRIPTIONS.handoff, icon: "send", enabled: false, sortOrder: 140, panelEnabled: true, panelSortOrder: 140, config: { targetApp: "ChatGPT" } },
];
