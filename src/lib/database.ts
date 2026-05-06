import Database from "@tauri-apps/plugin-sql";
import { DEFAULT_AI_FEATURE, DEFAULT_CUSTOM_PROMPT_TEMPLATE, DEFAULT_EXTRACT_FEATURE, DEFAULT_PANELS, DEFAULT_PROMPT_TEMPLATE, DEFAULT_REWRITE_FEATURE, DEFAULT_SETTINGS, DEFAULT_TOOLS, DEFAULT_TRANSLATION_FEATURE } from "./defaults";
import { isFeatureIcon } from "./featureIcons";
import { currentIsoDate, isTauriRuntime } from "./platform";
import type { AiFeature, AiFeatureIcon, AiFeatureKind, AiOutputMode, AppSettings, LearningEntryInput, LearningEntryType, NoteEntry, NoteInput, Panel, ReviewUpdate, TagEntry, ToolbarTool, WordEntry, WordStatus } from "../types";

type SqlDatabase = Awaited<ReturnType<typeof Database.load>>;

const WORDS_KEY = "lexi.words";
const SETTINGS_KEY = "lexi.settings";
const AI_FEATURES_KEY = "lexi.aiFeatures";
const POPUP_POSITION_KEY = "popupCardPosition";
const POPUP_SIZE_KEY = "popupCardSize";
const TOOL_SETTINGS_KEY = "toolbar_tools";
const NOTES_KEY = "lexi.notes";
const TAGS_KEY = "lexi.tags";

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

export async function loadToolbarTools(): Promise<ToolbarTool[]> {
  if (!isTauriRuntime()) return loadBrowserToolbarTools();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ value: string }>>(
    "SELECT value FROM settings WHERE key = $1 LIMIT 1",
    [TOOL_SETTINGS_KEY],
  );

  if (!rows[0]?.value) return DEFAULT_TOOLS.map((tool) => ({ ...tool }));

  try {
    const saved = JSON.parse(rows[0].value) as Array<{ id: string; enabled: boolean; sortOrder: number; panelEnabled?: boolean; panelSortOrder?: number; config?: Record<string, unknown>; icon?: string }>;
    return DEFAULT_TOOLS.map((defaultTool) => {
      const override = saved.find((item) => item.id === defaultTool.id);
      return {
        ...defaultTool,
        icon: (override?.icon && isFeatureIcon(override.icon)) ? override.icon : defaultTool.icon,
        enabled: override?.enabled ?? defaultTool.enabled,
        sortOrder: override?.sortOrder ?? defaultTool.sortOrder,
        panelEnabled: override?.panelEnabled ?? defaultTool.panelEnabled,
        panelSortOrder: override?.panelSortOrder ?? defaultTool.panelSortOrder,
        config: override?.config ?? defaultTool.config,
      };
    });
  } catch {
    return DEFAULT_TOOLS.map((tool) => ({ ...tool }));
  }
}

export async function saveToolbarTools(tools: ToolbarTool[]): Promise<void> {
  const data = tools.map((tool) => ({ id: tool.id, enabled: tool.enabled, sortOrder: tool.sortOrder, panelEnabled: tool.panelEnabled, panelSortOrder: tool.panelSortOrder, config: tool.config, icon: tool.icon }));

  if (!isTauriRuntime()) {
    localStorage.setItem("lexi.toolbarTools", JSON.stringify(data));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ($1, $2)", [
    TOOL_SETTINGS_KEY,
    JSON.stringify(data),
  ]);
}

// ── Panels ──────────────────────────────────────────────

export async function listPanels(): Promise<Panel[]> {
  if (!isTauriRuntime()) {
    const raw = localStorage.getItem("lexi.panels");
    const rows: Panel[] = raw ? JSON.parse(raw) : [];
    return withBuiltInPanels(rows);
  }
  const db = await getSqlDatabase();
  const rows = await db.select<PanelRow[]>("SELECT * FROM panels ORDER BY sort_order");
  return withBuiltInPanels(rows.map(panelFromRow));
}

export async function savePanel(panel: Panel): Promise<void> {
  if (!isTauriRuntime()) {
    const panels = await listPanels();
    const idx = panels.findIndex((p) => p.id === panel.id);
    if (idx >= 0) panels[idx] = panel;
    else panels.push(panel);
    localStorage.setItem("lexi.panels", JSON.stringify(panels));
    return;
  }
  const db = await getSqlDatabase();
  await db.execute(
    `INSERT INTO panels (id, name, icon, enabled, sort_order)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT(id) DO UPDATE SET name=$2, icon=$3, enabled=$4, sort_order=$5`,
    [panel.id, panel.name, panel.icon, panel.enabled ? 1 : 0, panel.sortOrder]
  );
}

function loadBrowserToolbarTools(): ToolbarTool[] {
  const saved = localStorage.getItem("lexi.toolbarTools");
  if (!saved) return DEFAULT_TOOLS.map((tool) => ({ ...tool }));

  try {
    const overrides = JSON.parse(saved) as Array<{ id: string; enabled: boolean; sortOrder: number; config?: Record<string, unknown>; icon?: string }>;
    return DEFAULT_TOOLS.map((defaultTool) => {
      const override = overrides.find((item) => item.id === defaultTool.id);
      return {
        ...defaultTool,
        icon: (override?.icon && isFeatureIcon(override.icon)) ? override.icon : defaultTool.icon,
        enabled: override?.enabled ?? defaultTool.enabled,
        sortOrder: override?.sortOrder ?? defaultTool.sortOrder,
        config: override?.config ?? defaultTool.config,
      };
    });
  } catch {
    return DEFAULT_TOOLS.map((tool) => ({ ...tool }));
  }
}

export async function listAiFeatures(): Promise<AiFeature[]> {
  if (!isTauriRuntime()) return loadBrowserAiFeatures();

  const db = await getSqlDatabase();
  const rows = await db.select<AiFeatureRow[]>(
    `SELECT id, name, kind, prompt_template, output_mode, enabled, sort_order,
            auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, created_at, updated_at
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
       auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, created_at, updated_at)
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
       speech_enabled = excluded.speech_enabled,
       icon = excluded.icon,
       is_builtin = excluded.is_builtin,
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
      normalized.speechEnabled ? 1 : 0,
      normalized.icon,
      normalized.isBuiltin ? 1 : 0,
      now,
    ],
  );
}

export async function deleteAiFeature(id: string) {
  if (!isTauriRuntime()) {
    saveBrowserAiFeatures(loadBrowserAiFeatures().filter((feature) => feature.id !== id && !feature.isBuiltin));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("DELETE FROM ai_features WHERE id = $1 AND is_builtin = 0", [id]);
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
    sqlDatabase = await Database.load("sqlite:lexi.db");
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
    const features = [DEFAULT_TRANSLATION_FEATURE, DEFAULT_EXTRACT_FEATURE, DEFAULT_REWRITE_FEATURE, DEFAULT_AI_FEATURE];
    saveBrowserAiFeatures(features);
    return features;
  }

  try {
    const parsed = JSON.parse(saved) as AiFeature[];
    const normalized = withBuiltInFeatures(parsed.map(normalizedAiFeature)).sort(sortAiFeatures);
    if (normalized.length > 0) return normalized;
  } catch {
    // Fall through to the built-in features.
  }

  const features = [DEFAULT_TRANSLATION_FEATURE, DEFAULT_EXTRACT_FEATURE, DEFAULT_REWRITE_FEATURE, DEFAULT_AI_FEATURE];
  saveBrowserAiFeatures(features);
  return features;
}

function saveBrowserAiFeatures(features: AiFeature[]) {
  localStorage.setItem(AI_FEATURES_KEY, JSON.stringify(withBuiltInFeatures(features.map(normalizedAiFeature)).sort(sortAiFeatures)));
}

function loadBrowserPopupPosition() {
  return parseWindowPosition(localStorage.getItem(POPUP_POSITION_KEY));
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
  if (key === "toolbarEnabled") return value === "true";
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
  speech_enabled?: number | null;
  icon?: string | null;
  is_builtin?: number | null;
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
    speechEnabled: row.speech_enabled === 1,
    icon: parseFeatureIcon(row.icon, parseAiFeatureKind(row.kind)),
    isBuiltin: row.is_builtin === 1,
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
    isBuiltin: true,
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
      isBuiltin: true,
    });
  } catch {
    return DEFAULT_TRANSLATION_FEATURE;
  }
}

function normalizedAiFeature(feature: Partial<AiFeature>): AiFeature {
  const rawId = stringValue(feature.id);
  const rawName = stringValue(feature.name);
  const rawPromptTemplate = stringValue(feature.promptTemplate);
  const isTranslation = feature.kind === "translation" || rawId === DEFAULT_TRANSLATION_FEATURE.id;
  const isExtract = rawId === DEFAULT_EXTRACT_FEATURE.id;
  return {
    id: builtInFeatureId(isTranslation) ?? (isExtract ? DEFAULT_EXTRACT_FEATURE.id : normalizedFeatureId(rawId || rawName)),
    name: rawName.trim() || defaultFeatureName(isTranslation) || (isExtract ? DEFAULT_EXTRACT_FEATURE.name : ""),
    kind: builtInFeatureKind(isTranslation) ?? parseAiFeatureKind(stringValue(feature.kind)),
    promptTemplate: normalizedFeaturePrompt(isTranslation, rawPromptTemplate),
    outputMode: isTranslation ? "plain_text" : parseAiOutputMode(stringValue(feature.outputMode)),
    enabled: feature.enabled !== false,
    sortOrder: Number.isFinite(feature.sortOrder) ? Math.round(Number(feature.sortOrder)) : defaultFeatureSortOrder(isTranslation),
    panelEnabled: feature.panelEnabled !== false,
    panelSortOrder: Number.isFinite(feature.panelSortOrder) ? Math.round(Number(feature.panelSortOrder)) : defaultPanelSortOrder(isTranslation),
    autoSaveToVocabulary: isTranslation ? (feature.autoSaveToVocabulary !== false) : (feature.autoSaveToVocabulary === true),
    targetLanguage: isTranslation ? stringValue(feature.targetLanguage).trim() || DEFAULT_TRANSLATION_FEATURE.targetLanguage : "",
    speechEnabled: typeof feature.speechEnabled === "boolean" ? feature.speechEnabled : isTranslation,
    icon: parseFeatureIcon(stringValue(feature.icon), builtInFeatureKind(isTranslation) ?? parseAiFeatureKind(stringValue(feature.kind))),
    isBuiltin: feature.isBuiltin === true,
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
  const builtIn = [DEFAULT_TRANSLATION_FEATURE, DEFAULT_EXTRACT_FEATURE, DEFAULT_REWRITE_FEATURE, DEFAULT_AI_FEATURE];
  const nextFeatures = [...features];

  for (const builtInFeature of builtIn) {
    const byId = nextFeatures.findIndex((f) => f.id === builtInFeature.id);
    if (byId >= 0) continue;

    const byName = nextFeatures.findIndex(
      (f) => f.name.toLowerCase() === builtInFeature.name.toLowerCase(),
    );
    if (byName >= 0) {
      nextFeatures[byName] = { ...nextFeatures[byName], id: builtInFeature.id };
    } else {
      nextFeatures.push(builtInFeature);
    }
  }

  return nextFeatures;
}

export function isBuiltInFeatureId(id: string) {
  return id === DEFAULT_TRANSLATION_FEATURE.id || id === DEFAULT_EXTRACT_FEATURE.id || id === DEFAULT_REWRITE_FEATURE.id || id === DEFAULT_AI_FEATURE.id;
}

function builtInFeatureId(isTranslation: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.id;
  return undefined;
}

function builtInFeatureKind(isTranslation: boolean): AiFeatureKind | undefined {
  if (isTranslation) return "translation";
  return undefined;
}

function defaultFeatureName(isTranslation: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.name;
  return "Custom feature";
}

function defaultFeatureSortOrder(isTranslation: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.sortOrder;
  return 0;
}

function defaultPanelSortOrder(isTranslation: boolean) {
  if (isTranslation) return DEFAULT_TRANSLATION_FEATURE.panelSortOrder;
  return 0;
}


function parseFeatureIcon(value: string | null | undefined, kind: AiFeatureKind): AiFeatureIcon {
  if (value && isFeatureIcon(value)) return value;
  if (kind === "translation") return DEFAULT_TRANSLATION_FEATURE.icon;
  return "wand";
}

interface PanelRow {
  id: string;
  name: string;
  icon: string;
  enabled: number;
  sort_order: number;
}

function panelFromRow(row: PanelRow): Panel {
  return {
    id: row.id,
    name: row.name,
    icon: (row.icon as AiFeatureIcon) || "wand",
    enabled: row.enabled !== 0,
    sortOrder: row.sort_order ?? 0,
  };
}

function withBuiltInPanels(panels: Panel[]): Panel[] {
  for (const def of DEFAULT_PANELS) {
    if (!panels.some((p) => p.id === def.id)) {
      panels.push({ ...def });
    }
  }
  return panels.sort((a, b) => a.sortOrder - b.sortOrder);
}

// ── Tags ──────────────────────────────────────────────

export async function listTags(): Promise<TagEntry[]> {
  if (!isTauriRuntime()) return loadBrowserTags();

  const db = await getSqlDatabase();
  return db.select<TagEntry[]>("SELECT * FROM tags ORDER BY id");
}

export async function saveTag(name: string): Promise<TagEntry> {
  const trimmed = name.trim();
  if (!trimmed) throw new Error("Tag name cannot be empty");

  if (!isTauriRuntime()) {
    const tags = loadBrowserTags();
    const existing = tags.find((t) => t.name === trimmed);
    if (existing) return existing;
    const tag: TagEntry = { id: Date.now(), name: trimmed };
    tags.push(tag);
    saveBrowserTags(tags);
    return tag;
  }

  const db = await getSqlDatabase();
  await db.execute("INSERT OR IGNORE INTO tags (name) VALUES ($1)", [trimmed]);
  const rows = await db.select<TagEntry[]>("SELECT * FROM tags WHERE name = $1", [trimmed]);
  return rows[0];
}

export async function deleteTag(id: number): Promise<void> {
  if (!isTauriRuntime()) {
    const tags = loadBrowserTags().filter((t) => t.id !== id);
    saveBrowserTags(tags);
    // Move affected notes to "Tmp"
    const notes = loadBrowserNotes();
    for (const note of notes) {
      if (note.tags.length > 0) {
        note.tags = ["Tmp"];
      }
    }
    saveBrowserNotes(notes);
    return;
  }

  const db = await getSqlDatabase();
  // Move affected notes to "Tmp" before deleting tag
  await db.execute("INSERT OR IGNORE INTO tags (name) VALUES ('Tmp')");
  const tmpRows = await db.select<TagEntry[]>("SELECT * FROM tags WHERE name = 'Tmp'");
  const tmpTagId = tmpRows[0].id;
  // Find notes that only have this tag
  const affected = await db.select<{ note_id: number }[]>(
    "SELECT DISTINCT note_id FROM note_tags WHERE tag_id = $1", [id],
  );
  for (const row of affected) {
    await db.execute("DELETE FROM note_tags WHERE note_id = $1", [row.note_id]);
    await db.execute("INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES ($1, $2)", [row.note_id, tmpTagId]);
  }
  await db.execute("DELETE FROM tags WHERE id = $1", [id]);
}

export async function renameTag(id: number, newName: string): Promise<void> {
  const trimmed = newName.trim();
  if (!trimmed) return;

  if (!isTauriRuntime()) {
    const tags = loadBrowserTags();
    const tag = tags.find((t) => t.id === id);
    if (tag) tag.name = trimmed;
    saveBrowserTags(tags);
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("UPDATE tags SET name = $1 WHERE id = $2", [trimmed, id]);
}

// ── Notes ──────────────────────────────────────────────

export async function listNotes(): Promise<NoteEntry[]> {
  if (!isTauriRuntime()) return loadBrowserNotes();

  const db = await getSqlDatabase();
  const rows = await db.select<Array<{ id: number; name: string | null; content: string; created_at: string; tag_names: string | null }>>(
    `SELECT n.*, GROUP_CONCAT(t.name) AS tag_names
     FROM notes n
     LEFT JOIN note_tags nt ON n.id = nt.note_id
     LEFT JOIN tags t ON t.id = nt.tag_id
     GROUP BY n.id
     ORDER BY datetime(n.created_at) DESC`,
  );
  return rows.map((row) => ({
    id: row.id,
    name: row.name,
    content: row.content,
    created_at: row.created_at,
    tags: row.tag_names ? row.tag_names.split(",") : [],
  }));
}

export async function addNote(input: NoteInput): Promise<NoteEntry> {
  const tagName = input.tagName ?? "Tmp";

  if (!isTauriRuntime()) {
    const notes = loadBrowserNotes();
    const tags = loadBrowserTags();
    let tag = tags.find((t) => t.name === tagName);
    if (!tag) {
      tag = { id: Date.now(), name: tagName };
      tags.push(tag);
      saveBrowserTags(tags);
    }
    const note: NoteEntry = {
      id: Date.now(),
      name: input.name ?? null,
      content: input.content,
      created_at: currentIsoDate(),
      tags: [tagName],
    };
    notes.unshift(note);
    saveBrowserNotes(notes);
    return note;
  }

  const db = await getSqlDatabase();
  const tag = await saveTag(tagName);
  const createdAt = currentIsoDate();
  await db.execute(
    "INSERT INTO notes (name, content, created_at) VALUES ($1, $2, $3)",
    [input.name ?? null, input.content, createdAt],
  );
  const rows = await db.select<Array<{ id: number }>>("SELECT id FROM notes ORDER BY id DESC LIMIT 1");
  const noteId = rows[0].id;
  await db.execute("INSERT INTO note_tags (note_id, tag_id) VALUES ($1, $2)", [noteId, tag.id]);

  const noteRows = await db.select<Array<{ id: number; name: string | null; content: string; created_at: string; tag_names: string | null }>>(
    `SELECT n.*, GROUP_CONCAT(t.name) AS tag_names
     FROM notes n
     LEFT JOIN note_tags nt ON n.id = nt.note_id
     LEFT JOIN tags t ON t.id = nt.tag_id
     WHERE n.id = $1
     GROUP BY n.id`,
    [noteId],
  );
  const row = noteRows[0];
  return {
    id: row.id,
    name: row.name,
    content: row.content,
    created_at: row.created_at,
    tags: row.tag_names ? row.tag_names.split(",") : [],
  };
}

export async function updateNote(id: number, update: { name?: string | null; content?: string }): Promise<void> {
  if (!isTauriRuntime()) {
    const notes = loadBrowserNotes();
    const note = notes.find((n) => n.id === id);
    if (note) {
      if (update.name !== undefined) note.name = update.name;
      if (update.content !== undefined) note.content = update.content;
      saveBrowserNotes(notes);
    }
    return;
  }

  const db = await getSqlDatabase();
  const fields: string[] = [];
  const values: unknown[] = [];
  if (update.name !== undefined) { fields.push("name = $1"); values.push(update.name); }
  if (update.content !== undefined) { fields.push("content = $" + String(values.length + 1)); values.push(update.content); }
  if (fields.length === 0) return;
  values.push(id);
  await db.execute(`UPDATE notes SET ${fields.join(", ")} WHERE id = $${values.length}`, values);
}

export async function deleteNote(id: number): Promise<void> {
  if (!isTauriRuntime()) {
    saveBrowserNotes(loadBrowserNotes().filter((n) => n.id !== id));
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("DELETE FROM notes WHERE id = $1", [id]);
}

export async function setNoteTag(noteId: number, tagName: string): Promise<void> {
  const tag = await saveTag(tagName);

  if (!isTauriRuntime()) {
    const notes = loadBrowserNotes();
    const note = notes.find((n) => n.id === noteId);
    if (note) note.tags = [tagName];
    saveBrowserNotes(notes);
    return;
  }

  const db = await getSqlDatabase();
  await db.execute("DELETE FROM note_tags WHERE note_id = $1", [noteId]);
  await db.execute("INSERT INTO note_tags (note_id, tag_id) VALUES ($1, $2)", [noteId, tag.id]);
}

function loadBrowserTags(): TagEntry[] {
  const raw = localStorage.getItem(TAGS_KEY);
  if (!raw) return [{ id: 1, name: "Tmp" }];
  try {
    return JSON.parse(raw) as TagEntry[];
  } catch {
    return [{ id: 1, name: "Tmp" }];
  }
}

function saveBrowserTags(tags: TagEntry[]): void {
  localStorage.setItem(TAGS_KEY, JSON.stringify(tags));
}

function loadBrowserNotes(): NoteEntry[] {
  const raw = localStorage.getItem(NOTES_KEY);
  if (!raw) return [];
  try {
    return JSON.parse(raw) as NoteEntry[];
  } catch {
    return [];
  }
}

function saveBrowserNotes(notes: NoteEntry[]): void {
  localStorage.setItem(NOTES_KEY, JSON.stringify(notes));
}
