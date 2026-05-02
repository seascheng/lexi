export type DisplayMode = "always_bar" | "auto_bar" | "popup_card";
export type AppTheme = "dark" | "light";
export type DockMode = "dock_and_menu_bar" | "menu_bar_only";
export type BackgroundStyle = "solid" | "transparent" | "macos_glass_clear";
export type WordStatus = "new" | "learning" | "mastered";
export type ReviewRating = "again" | "hard" | "good" | "easy";
export type AiFeatureKind = "translation" | "review" | "custom";
export type AiOutputMode = "translation_json" | "plain_text";
export type AiFeatureIcon = "languages" | "wand" | "pen" | "sparkles" | "book-plus" | "highlighter" | "file-text" | "message";
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
  displayMode: DisplayMode;
  theme: AppTheme;
  windowOpacity: number;
  backgroundStyle: BackgroundStyle;
  dockMode: DockMode;
  shortcut: string;
  apiBaseUrl: string;
  apiKey: string;
  model: string;
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
  autoSaveToVocabulary: boolean;
  targetLanguage: string;
  reviewIntervalSeconds: number;
  speechEnabled: boolean;
  icon: AiFeatureIcon;
  createdAt?: string;
  updatedAt?: string;
}

export interface AiRunResult {
  outputText: string;
  translation?: TranslationResult;
}
