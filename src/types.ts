export type DisplayMode = "always_bar" | "auto_bar" | "popup_card";
export type AppTheme = "dark" | "light";
export type DockMode = "dock_and_menu_bar" | "menu_bar_only";
export type BackgroundStyle = "solid" | "transparent" | "macos_glass_clear";
export type WordStatus = "new" | "learning" | "mastered";
export type ReviewRating = "again" | "hard" | "good" | "easy";

export interface TranslationResult {
  word: string;
  translation: string;
  pos: string;
  definition: string;
  example: string;
}

export interface WordEntry extends TranslationResult {
  id: number;
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
  targetLanguage: string;
  promptTemplate: string;
  autoSave: boolean;
}

export interface ReviewUpdate {
  status: WordStatus;
  review_count: number;
  next_review: string;
  ease_factor: number;
  interval: number;
}
