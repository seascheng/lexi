export type AppTheme = "dark" | "light";
export type AccentColor = "default" | "blue" | "green" | "red" | "orange" | "purple" | "custom";
export type DockMode = "dock_and_menu_bar" | "menu_bar_only";
export type BackgroundStyle = "solid" | "transparent" | "macos_glass_clear";
export type WordStatus = "new" | "learning" | "mastered";
export type ReviewRating = "again" | "hard" | "good" | "easy";
export type AiFeatureKind = "translation" | "custom";
export type AiOutputMode = "translation_json" | "plain_text";
export type AiFeatureIcon = "languages" | "wand" | "pen" | "sparkles" | "book-plus" | "book-open" | "highlighter" | "file-text" | "message" | "clipboard" | "copy" | "search" | "volume" | "notebook-pen" | "send" | "type" | "heading" | "bookmark" | "star" | "heart" | "flag" | "tag" | "hash" | "check-circle" | "info" | "help-circle" | "shield" | "globe" | "compass" | "mail" | "at-sign" | "share-2" | "image" | "mic" | "sun" | "moon" | "zap" | "flame" | "user" | "clock" | "calendar" | "code" | "terminal" | "graduation-cap" | "brain" | "lightbulb" | "target" | "trophy" | "rocket" | "palette" | "pencil" | "refresh-cw" | "download" | "upload" | "link" | "eye" | "settings" | "wrench" | "plus" | "filter" | "folder" | "file" | "bold" | "italic" | "diamond";
export type ToolbarToolId = "copy" | "search" | "read" | "note" | "handoff";
export type LearningEntryType = "word" | "phrase" | "pattern";

export interface TranslationResult {
  word: string;
  translation: string;
  pos: string;
  definition: string;
  example: string;
}

export interface LearningEntryInput extends TranslationResult {
  entry_type?: LearningEntryType;
  source_text?: string;
  note?: string;
}

export interface WordEntry extends TranslationResult {
  id: number;
  entry_type: LearningEntryType;
  source_text: string | null;
  note: string | null;
  status: WordStatus;
  created_at: string;
  review_count: number;
  next_review: string | null;
  ease_factor: number;
  interval: number;
}

export interface AppSettings {
  theme: AppTheme;
  accentColor: AccentColor;
  customAccentColor: string;
  windowOpacity: number;
  backgroundStyle: BackgroundStyle;
  dockMode: DockMode;
  toolbarEnabled: boolean;
  excludedToolbarApps: string[];
  activePanelId: string | null;
  apiBaseUrl: string;
  apiKey: string;
  model: string;
  popupShortcut: string;
  autoStart: boolean;
}

export interface ReviewUpdate {
  status: WordStatus;
  review_count: number;
  next_review: string;
  ease_factor: number;
  interval: number;
}

export interface AiFeature {
  id: string;
  name: string;
  kind: AiFeatureKind;
  promptTemplate: string;
  outputMode: AiOutputMode;
  enabled: boolean;
  sortOrder: number;
  panelEnabled: boolean;
  panelSortOrder: number;
  autoSaveToVocabulary: boolean;
  targetLanguage: string;
  speechEnabled: boolean;
  thinkingEnabled: boolean;
  icon: AiFeatureIcon;
  isBuiltin: boolean;
  createdAt?: string;
  updatedAt?: string;
}

export interface ToolbarTool {
  id: ToolbarToolId;
  name: string;
  description: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
  panelEnabled: boolean;
  panelSortOrder: number;
  config: Record<string, unknown>;
}

export type PanelId = string;

export interface Panel {
  id: PanelId;
  name: string;
  icon: AiFeatureIcon;
  enabled: boolean;
  sortOrder: number;
}

export interface AiRunResult {
  outputText: string;
  translation?: TranslationResult;
}

export interface StreamChunkEvent {
  run_id: string;
  chunk?: string;
  done: boolean;
  error?: string;
  translation?: TranslationResult;
}

export interface NoteEntry {
  id: number;
  name: string | null;
  content: string;
  created_at: string;
  tags: string[];
}

export interface TagEntry {
  id: number;
  name: string;
}

export interface NoteInput {
  name?: string | null;
  content: string;
  tagName?: string;
}
