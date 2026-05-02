import Database from "@tauri-apps/plugin-sql";
import { DEFAULT_CUSTOM_PROMPT_TEMPLATE, DEFAULT_PROMPT_TEMPLATE, DEFAULT_REVIEW_FEATURE, DEFAULT_SETTINGS, DEFAULT_TRANSLATION_FEATURE } from "./defaults";
import { isFeatureIcon } from "./featureIcons";
import { currentIsoDate, isTauriRuntime } from "./platform";
import type { AiFeature, AiFeatureIcon, AiFeatureKind, AiOutputMode, AppSettings, LearningEntryInput, LearningEntryType, ReviewUpdate, WordEntry, WordStatus } from "../types";

type SqlDatabase = Awaited<ReturnType<typeof Database.load>>;

const WORDS_KEY = "englist.words";
const SETTINGS_KEY = "englist.settings";
const AI_FEATURES_KEY = "englist.aiFeatures";
const POPUP_POSITION_KEY = "popupCardPosition";
const POPUP_SIZE_KEY = "popupCardSize";

export interface WindowPosition {
  x: number;
  y: number;
}

export interface WindowSize {
  width: number;
  height: number;
}

let sqlDatabase: SqlDatabase | null = null;

export async function loadSettings(): Promise<AppSettings> {
  if (!isTauriRuntime()) return loadBrowserSettings();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ key: string; value: string }>>("SELECT key, value FROM settings");
  return rows.reduce((settings, row) => {
    return { ...settings, [row.key]: parseSettingValue(row.key, row.value) };
  }, DEFAULT_SETTINGS);
}

export async function saveSettings(settings: AppSettings) {
  if (!isTauriRuntime()) {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
    return;
  }

  const db = await getSqlDatabase();
  for (const [key, value] of Object.entries(settings)) {
    await db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)", [
      key,
      serializeSettingValue(value),
    ]);
  }
}

export async function loadPopupPosition(): Promise<WindowPosition | null> {
  if (!isTauriRuntime()) return loadBrowserPopupPosition();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ value: string }>>(
    "SELECT value FROM settings WHERE key = $1 LIMIT 1",
    [POPUP_POSITION_KEY],
  );

  return parseWindowPosition(rows[0]?.value);
}

export async function savePopupPosition(position: WindowPosition) {
  const serialized = JSON.stringify(normalizedWindowPosition(position));

  if (!isTauriRuntime()) {
    localStorage.setItem(POPUP_POSITION_KEY, serialized);
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)", [
    POPUP_POSITION_KEY,
    serialized,
  ]);
}

export async function loadPopupSize(): Promise<WindowSize | null> {
  if (!isTauriRuntime()) return loadBrowserPopupSize();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ value: string }>>(
    "SELECT value FROM settings WHERE key = $1 LIMIT 1",
    [POPUP_SIZE_KEY],
  );

  return parseWindowSize(rows[0]?.value);
}

export async function savePopupSize(size: WindowSize) {
  const serialized = JSON.stringify(normalizedWindowSize(size));

  if (!isTauriRuntime()) {
    localStorage.setItem(POPUP_SIZE_KEY, serialized);
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)", [
    POPUP_SIZE_KEY,
    serialized,
  ]);
}

export async function listAiFeatures(): Promise<AiFeature[]> {
  if (!isTauriRuntime()) return loadBrowserAiFeatures();

  const db = await getSqlDatabase();
  const rows = await db.select<AiFeatureRow[]>(
    `SELECT id, name, kind, prompt_template, output_mode, enabled, sort_order,
            auto_save_to_vocabulary, target_language, review_interval_seconds, speech_enabled, icon, created_at, updated_at
     FROM ai_features
     ORDER BY sort_order ASC, name ASC`,
  );

  if (rows.length > 0) return withBuiltInFeatures(rows.map(aiFeatureFromRow)).sort(sortAiFeatures);

  const feature = await legacyTranslationFeature(db);
  await saveAiFeature(feature);
  return withBuiltInFeatures([feature]).sort(sortAiFeatures);
}

export async function saveAiFeature(feature: AiFeature) {
  const normalized = normalizedAiFeature(feature);

  if (!isTauriRuntime()) {
    const features = loadBrowserAiFeatures();
    const nextFeatures = features.some((item) => item.id === normalized.id)
      ? features.map((item) => (item.id === normalized.id ? normalized : item))
      : [...features, normalized];
    saveBrowserAiFeatures(nextFeatures);
    return;
  }

  const db = await getSqlDatabase();
  const now = currentIsoDate();
  await db.execute(
    `INSERT INTO ai_features
      (id, name, kind, prompt_template, output_mode, enabled, sort_order,
       auto_save_to_vocabulary, target_language, review_interval_seconds, speech_enabled, icon, created_at, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
     ON CONFLICT(id) DO UPDATE SET
       name = excluded.name,
       kind = excluded.kind,
       prompt_template = excluded.prompt_template,
       output_mode = excluded.output_mode,
       enabled = excluded.enabled,
       sort_order = excluded.sort_order,
       auto_save_to_vocabulary = excluded.auto_save_to_vocabulary,
       target_language = excluded.target_language,
       review_interval_seconds = excluded.review_interval_seconds,
       speech_enabled = excluded.speech_enabled,
       icon = excluded.icon,
       updated_at = excluded.updated_at`,
    [
      normalized.id,
      normalized.name,
      normalized.kind,
      normalized.promptTemplate,
      normalized.outputMode,
      normalized.enabled ? 1 : 0,
      normalized.sortOrder,
      normalized.autoSaveToVocabulary ? 1 : 0,
      normalized.targetLanguage,
      normalized.reviewIntervalSeconds,
      normalized.speechEnabled ? 1 : 0,
      normalized.icon,
      now,
    ],
  );
}

export async function deleteAiFeature(id: string) {
  if (isBuiltInFeatureId(id)) return;

  if (!isTauriRuntime()) {
    saveBrowserAiFeatures(loadBrowserAiFeatures().filter((feature) => feature.id !== id));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("DELETE FROM ai_features WHERE id = $1 AND kind NOT IN ('translation', 'review')", [id]);
}

export async function listWords(): Promise<WordEntry[]> {
  if (!isTauriRuntime()) return loadBrowserWords();

  const db = await getSqlDatabase();
  return db.select<WordEntry[]>(
    "SELECT * FROM words ORDER BY datetime(created_at) DESC, id DESC",
  );
}

export async function addWord(result: LearningEntryInput): Promise<WordEntry> {
  if (!isTauriRuntime()) return addBrowserWord(result);

  const db = await getSqlDatabase();
  const createdAt = currentIsoDate();
  const nextReview = createdAt;
  const entry = normalizedLearningEntryInput(result);

  await db.execute(
    `INSERT INTO words
      (word, translation, pos, definition, example, entry_type, source_text, note,
       status, created_at, review_count, next_review, ease_factor, interval)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'new', $9, 0, $10, 2.5, 0)`,
    [
      entry.word,
      entry.translation,
      entry.pos,
      entry.definition,
      entry.example,
      entry.entry_type,
      entry.source_text,
      entry.note,
      createdAt,
      nextReview,
    ],
  );

  const rows = await db.select<WordEntry[]>("SELECT * FROM words ORDER BY id DESC LIMIT 1");
  return rows[0];
}

export async function deleteWord(id: number) {
  if (!isTauriRuntime()) {
    saveBrowserWords(loadBrowserWords().filter((word) => word.id !== id));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("DELETE FROM words WHERE id = $1", [id]);
}

export async function updateWordStatus(id: number, status: WordStatus) {
  if (!isTauriRuntime()) {
    saveBrowserWords(
      loadBrowserWords().map((word) => (word.id === id ? { ...word, status } : word)),
    );
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("UPDATE words SET status = $1 WHERE id = $2", [status, id]);
}

export async function applyReviewUpdate(id: number, update: ReviewUpdate) {
  if (!isTauriRuntime()) {
    saveBrowserWords(
      loadBrowserWords().map((word) => (word.id === id ? { ...word, ...update } : word)),
    );
    return;
  }

  const db = await getSqlDatabase();
  await db.execute(
    `UPDATE words
     SET status = $1, review_count = $2, next_review = $3, ease_factor = $4, interval = $5
     WHERE id = $6`,
    [
      update.status,
      update.review_count,
      update.next_review,
      update.ease_factor,
      update.interval,
      id,
    ],
  );
}

export function dueWords(words: WordEntry[]) {
  const now = new Date();
  return words.filter((word) => {
    if (word.status === "mastered") return false;
    if (!word.next_review) return true;
    return new Date(word.next_review) <= now;
  });
}

async function getSqlDatabase() {
  if (!sqlDatabase) {
    sqlDatabase = await Database.load("sqlite:englist.db");
  }
  return sqlDatabase;
}

function loadBrowserSettings(): AppSettings {
  const saved = localStorage.getItem(SETTINGS_KEY);
  if (!saved) return DEFAULT_SETTINGS;

  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(saved) };
  } catch {
    return DEFAULT_SETTINGS;
  }
}

function loadBrowserAiFeatures(): AiFeature[] {
  const saved = localStorage.getItem(AI_FEATURES_KEY);
  if (!saved) {
    const feature = browserLegacyTranslationFeature();
    saveBrowserAiFeatures([feature]);
    return [feature];
  }

  try {
    const parsed = JSON.parse(saved) as AiFeature[];
    const normalized = withBuiltInFeatures(parsed.map(normalizedAiFeature)).sort(sortAiFeatures);
    if (normalized.length > 0) return normalized;
  } catch {
    // Fall through to the built-in translation feature.
  }

  const feature = browserLegacyTranslationFeature();
  saveBrowserAiFeatures([feature]);
  return [feature];
}

function saveBrowserAiFeatures(features: AiFeature[]) {
  localStorage.setItem(AI_FEATURES_KEY, JSON.stringify(withBuiltInFeatures(features.map(normalizedAiFeature)).sort(sortAiFeatures)));
}

function loadBrowserPopupPosition() {
  return parseWindowPosition(localStorage.getItem(POPUP_POSITION_KEY));
}

function loadBrowserPopupSize() {
  return parseWindowSize(localStorage.getItem(POPUP_SIZE_KEY));
}

function loadBrowserWords(): WordEntry[] {
  const saved = localStorage.getItem(WORDS_KEY);
  if (!saved) return seedWords();

  try {
    return (JSON.parse(saved) as WordEntry[]).map(normalizedStoredWord);
  } catch {
    return seedWords();
  }
}

function addBrowserWord(result: LearningEntryInput): WordEntry {
  const words = loadBrowserWords();
  const entry = normalizedLearningEntryInput(result);
  const word: WordEntry = {
    ...entry,
    id: Date.now(),
    status: "new",
    created_at: currentIsoDate(),
    review_count: 0,
    next_review: currentIsoDate(),
    ease_factor: 2.5,
    interval: 0,
  };
  saveBrowserWords([word, ...words]);
  return word;
}

function saveBrowserWords(words: WordEntry[]) {
  localStorage.setItem(WORDS_KEY, JSON.stringify(words.map(normalizedStoredWord)));
}

function seedWords(): WordEntry[] {
  return [
    {
      id: 1,
      word: "resilient",
      translation: "有韧性的",
      pos: "adjective",
      definition: "Able to recover quickly after difficulty or change.",
      example: "A resilient learner turns mistakes into better habits.",
      entry_type: "word",
      source_text: null,
      note: null,
      status: "learning",
      created_at: currentIsoDate(),
      review_count: 1,
      next_review: currentIsoDate(),
      ease_factor: 2.5,
      interval: 1,
    },
  ];
}

function parseSettingValue(key: string, value: string) {
  if (key === "windowOpacity") return parseWindowOpacity(value);
  return value;
}

function normalizedLearningEntryInput(result: LearningEntryInput): Required<LearningEntryInput> {
  return {
    word: result.word.trim(),
    translation: result.translation.trim(),
    pos: result.pos.trim(),
    definition: result.definition.trim(),
    example: result.example.trim(),
    entry_type: normalizedEntryType(result.entry_type),
    source_text: result.source_text?.trim() ?? "",
    note: result.note?.trim() ?? "",
  };
}

function normalizedEntryType(value: LearningEntryType | undefined): LearningEntryType {
  if (value === "phrase" || value === "pattern") return value;
  return "word";
}

function normalizedStoredWord(word: WordEntry): WordEntry {
  return {
    ...word,
    entry_type: normalizedEntryType(word.entry_type),
    source_text: word.source_text ?? null,
    note: word.note ?? null,
  };
}

function serializeSettingValue(value: unknown) {
  return typeof value === "boolean" ? String(value) : String(value ?? "");
}

function parseWindowOpacity(value: string) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return DEFAULT_SETTINGS.windowOpacity;
  return Math.min(100, Math.max(0, Math.round(parsed)));
}

function parseWindowPosition(value: string | null | undefined): WindowPosition | null {
  if (!value) return null;

  try {
    const parsed = JSON.parse(value);
    if (!isWindowPosition(parsed)) return null;
    return normalizedWindowPosition(parsed);
  } catch {
    return null;
  }
}

function parseWindowSize(value: string | null | undefined): WindowSize | null {
  if (!value) return null;

  try {
    const parsed = JSON.parse(value);
    if (!isWindowSize(parsed)) return null;
    return normalizedWindowSize(parsed);
  } catch {
    return null;
  }
}

function normalizedWindowPosition(value: unknown): WindowPosition {
  if (!isWindowPosition(value)) return { x: 0, y: 0 };
  return {
    x: Math.round(value.x),
    y: Math.round(value.y),
  };
}

function normalizedWindowSize(value: unknown): WindowSize {
  if (!isWindowSize(value)) return { width: 360, height: 360 };
  return {
    width: Math.min(900, Math.max(360, Math.round(value.width))),
    height: Math.min(900, Math.max(360, Math.round(value.height))),
  };
}

function isWindowPosition(value: unknown): value is WindowPosition {
  if (!value || typeof value !== "object") return false;
  const position = value as Partial<WindowPosition>;
  return Number.isFinite(position.x) && Number.isFinite(position.y);
}

function isWindowSize(value: unknown): value is WindowSize {
  if (!value || typeof value !== "object") return false;
  const size = value as Partial<WindowSize>;
  return Number.isFinite(size.width) && Number.isFinite(size.height);
}

interface AiFeatureRow {
  id: string;
  name: string;
  kind: string;
  prompt_template: string;
  output_mode: string;
  enabled: number;
  sort_order: number;
  auto_save_to_vocabulary: number;
  target_language: string | null;
  review_interval_seconds?: number | null;
  speech_enabled?: number | null;
  icon?: string | null;
  created_at: string;
  updated_at: string;
}

function aiFeatureFromRow(row: AiFeatureRow): AiFeature {
  return normalizedAiFeature({
    id: row.id,
    name: row.name,
    kind: parseAiFeatureKind(row.kind),
    promptTemplate: row.prompt_template,
    outputMode: parseAiOutputMode(row.output_mode),
    enabled: row.enabled === 1,
    sortOrder: row.sort_order,
    autoSaveToVocabulary: row.auto_save_to_vocabulary === 1,
    targetLanguage: row.target_language ?? "",
    reviewIntervalSeconds: row.review_interval_seconds ?? DEFAULT_REVIEW_FEATURE.reviewIntervalSeconds,
    speechEnabled: row.speech_enabled === 1,
    icon: parseFeatureIcon(row.icon, parseAiFeatureKind(row.kind)),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  });
}

async function legacyTranslationFeature(db: SqlDatabase): Promise<AiFeature> {
  const rows = await db.select<Array<{ key: string; value: string }>>(
    "SELECT key, value FROM settings WHERE key IN ('promptTemplate', 'targetLanguage', 'autoSave')",
  );
  const legacy = Object.fromEntries(rows.map((row) => [row.key, row.value]));
  return normalizedAiFeature({
    ...DEFAULT_TRANSLATION_FEATURE,
    promptTemplate: legacy.promptTemplate || DEFAULT_TRANSLATION_FEATURE.promptTemplate,
    targetLanguage: legacy.targetLanguage || DEFAULT_TRANSLATION_FEATURE.targetLanguage,
    autoSaveToVocabulary: legacy.autoSave ? legacy.autoSave === "true" : DEFAULT_TRANSLATION_FEATURE.autoSaveToVocabulary,
  });
}

function browserLegacyTranslationFeature(): AiFeature {
  const saved = localStorage.getItem(SETTINGS_KEY);
  if (!saved) return DEFAULT_TRANSLATION_FEATURE;

  try {
    const legacy = JSON.parse(saved) as Record<string, unknown>;
    return normalizedAiFeature({
      ...DEFAULT_TRANSLATION_FEATURE,
      promptTemplate: typeof legacy.promptTemplate === "string" ? legacy.promptTemplate : DEFAULT_TRANSLATION_FEATURE.promptTemplate,
      targetLanguage: typeof legacy.targetLanguage === "string" ? legacy.targetLanguage : DEFAULT_TRANSLATION_FEATURE.targetLanguage,
      autoSaveToVocabulary: typeof legacy.autoSave === "boolean" ? legacy.autoSave : DEFAULT_TRANSLATION_FEATURE.autoSaveToVocabulary,
    });
  } catch {
    return DEFAULT_TRANSLATION_FEATURE;
  }
}

function normalizedAiFeature(feature: Partial<AiFeature>): AiFeature {
  const rawId = stringValue(feature.id);
  const rawName = stringValue(feature.name);
  const rawPromptTemplate = stringValue(feature.promptTemplate);
  const rawTargetLanguage = stringValue(feature.targetLanguage);
  const isTranslation = feature.kind === "translation" || rawId === DEFAULT_TRANSLATION_FEATURE.id;
  const isReview = feature.kind === "review" || rawId === DEFAULT_REVIEW_FEATURE.id;
  return {
    id: builtInFeatureId(isTranslation, isReview) ?? normalizedFeatureId(rawId || rawName),
    name: rawName.trim() || defaultFeatureName(isTranslation, isReview),
    kind: builtInFeatureKind(isTranslation, isReview) ?? parseAiFeatureKind(stringValue(feature.kind)),
    promptTemplate: isReview ? "" : normalizedFeaturePrompt(isTranslation, rawPromptTemplate),
    outputMode: isTranslation || isReview ? "plain_text" : parseAiOutputMode(stringValue(feature.outputMode)),
    enabled: feature.enabled !== false,
    sortOrder: Number.isFinite(feature.sortOrder) ? Math.round(Number(feature.sortOrder)) : defaultFeatureSortOrder(isTranslation, isReview),
    autoSaveToVocabulary: isTranslation && feature.autoSaveToVocabulary !== false,
    targetLanguage: isTranslation ? rawTargetLanguage.trim() || DEFAULT_TRANSLATION_FEATURE.targetLanguage : "",
    reviewIntervalSeconds: normalizedReviewInterval(feature.reviewIntervalSeconds),
    speechEnabled: normalizedSpeechEnabled(feature.speechEnabled, isTranslation, isReview),
    icon: parseFeatureIcon(stringValue(feature.icon), builtInFeatureKind(isTranslation, isReview) ?? parseAiFeatureKind(stringValue(feature.kind))),
    createdAt: stringValue(feature.createdAt),
    updatedAt: stringValue(feature.updatedAt),
  };
}

function stringValue(value: unknown) {
  return typeof value === "string" ? value : "";
}

function normalizedFeatureId(value: string) {
  const normalized = value
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (normalized.startsWith("custom-")) return normalized;
  return normalized ? `custom-${normalized}` : `custom-${Date.now()}`;
}

function parseAiFeatureKind(value: string): AiFeatureKind {
  if (value === "review") return "review";
  return value === "translation" ? "translation" : "custom";
}

function parseAiOutputMode(value: string): AiOutputMode {
  return value === "translation_json" ? "translation_json" : "plain_text";
}

function normalizedFeaturePrompt(isTranslation: boolean, promptTemplate: string) {
  const trimmed = promptTemplate.trim();
  if (!isTranslation) return trimmed || DEFAULT_CUSTOM_PROMPT_TEMPLATE;
  if (!trimmed || trimmed.includes("return strict JSON only")) return DEFAULT_PROMPT_TEMPLATE;
  return trimmed;
}

function sortAiFeatures(a: AiFeature, b: AiFeature) {
  return a.sortOrder - b.sortOrder || a.name.localeCompare(b.name);
}

function withBuiltInFeatures(features: AiFeature[]) {
  const nextFeatures = [...features];
  if (!nextFeatures.some((feature) => feature.id === DEFAULT_TRANSLATION_FEATURE.id)) {
    nextFeatures.push(DEFAULT_TRANSLATION_FEATURE);
  }
  if (!nextFeatures.some((feature) => feature.id === DEFAULT_REVIEW_FEATURE.id)) {
    nextFeatures.push(DEFAULT_REVIEW_FEATURE);
  }
  return nextFeatures;
}

function isBuiltInFeatureId(id: string) {
  return id === DEFAULT_TRANSLATION_FEATURE.id || id === DEFAULT_REVIEW_FEATURE.id;
}

function builtInFeatureId(isTranslation: boolean, isReview: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.id;
  if (isReview) return DEFAULT_REVIEW_FEATURE.id;
  return undefined;
}

function builtInFeatureKind(isTranslation: boolean, isReview: boolean): AiFeatureKind | undefined {
  if (isTranslation) return "translation";
  if (isReview) return "review";
  return undefined;
}

function defaultFeatureName(isTranslation: boolean, isReview: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.name;
  if (isReview) return DEFAULT_REVIEW_FEATURE.name;
  return "Custom feature";
}

function defaultFeatureSortOrder(isTranslation: boolean, isReview: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.sortOrder;
  if (isReview) return DEFAULT_REVIEW_FEATURE.sortOrder;
  return 0;
}

function normalizedReviewInterval(value: unknown) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return DEFAULT_REVIEW_FEATURE.reviewIntervalSeconds;
  return Math.min(3600, Math.max(5, Math.round(parsed)));
}

function normalizedSpeechEnabled(value: unknown, isTranslation: boolean, isReview: boolean) {
  if (typeof value === "boolean") return value;
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.speechEnabled;
  if (isReview) return DEFAULT_REVIEW_FEATURE.speechEnabled;
  return false;
}

function parseFeatureIcon(value: string | null | undefined, kind: AiFeatureKind): AiFeatureIcon {
  if (value && isFeatureIcon(value)) return value;
  if (kind === "translation") return DEFAULT_TRANSLATION_FEATURE.icon;
  if (kind === "review") return DEFAULT_REVIEW_FEATURE.icon;
  return "wand";
}
