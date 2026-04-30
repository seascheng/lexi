import Database from "@tauri-apps/plugin-sql";
import { DEFAULT_SETTINGS } from "./defaults";
import { currentIsoDate, isTauriRuntime } from "./platform";
import type { AppSettings, ReviewUpdate, TranslationResult, WordEntry, WordStatus } from "../types";

type SqlDatabase = Awaited<ReturnType<typeof Database.load>>;

const WORDS_KEY = "englist.words";
const SETTINGS_KEY = "englist.settings";
const POPUP_POSITION_KEY = "popupCardPosition";

export interface WindowPosition {
  x: number;
  y: number;
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

export async function listWords(): Promise<WordEntry[]> {
  if (!isTauriRuntime()) return loadBrowserWords();

  const db = await getSqlDatabase();
  return db.select<WordEntry[]>(
    "SELECT * FROM words ORDER BY datetime(created_at) DESC, id DESC",
  );
}

export async function addWord(result: TranslationResult): Promise<WordEntry> {
  if (!isTauriRuntime()) return addBrowserWord(result);

  const db = await getSqlDatabase();
  const createdAt = currentIsoDate();
  const nextReview = createdAt;

  await db.execute(
    `INSERT INTO words
      (word, translation, pos, definition, example, status, created_at, review_count, next_review, ease_factor, interval)
      VALUES ($1, $2, $3, $4, $5, 'new', $6, 0, $7, 2.5, 0)`,
    [
      result.word,
      result.translation,
      result.pos,
      result.definition,
      result.example,
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

function loadBrowserPopupPosition() {
  return parseWindowPosition(localStorage.getItem(POPUP_POSITION_KEY));
}

function loadBrowserWords(): WordEntry[] {
  const saved = localStorage.getItem(WORDS_KEY);
  if (!saved) return seedWords();

  try {
    return JSON.parse(saved) as WordEntry[];
  } catch {
    return seedWords();
  }
}

function addBrowserWord(result: TranslationResult): WordEntry {
  const words = loadBrowserWords();
  const word: WordEntry = {
    ...result,
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
  localStorage.setItem(WORDS_KEY, JSON.stringify(words));
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
  if (key === "autoSave") return value === "true";
  if (key === "windowOpacity") return parseWindowOpacity(value);
  return value;
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

function isWindowPosition(value: unknown): value is WindowPosition {
  if (!value || typeof value !== "object") return false;
  const position = value as Partial<WindowPosition>;
  return Number.isFinite(position.x) && Number.isFinite(position.y);
}
