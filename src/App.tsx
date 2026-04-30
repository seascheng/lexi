import { emit, listen } from "@tauri-apps/api/event";
import { BookOpen, Languages, Settings, Wand2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AppSettings, WordEntry } from "./types";
import { applyAppearanceSettings } from "./lib/appearance";
import { DEFAULT_SETTINGS } from "./lib/defaults";
import { listWords, loadSettings, saveSettings } from "./lib/database";
import { errorMessage } from "./lib/errors";
import {
  captureSelectedText,
  showTranslationError,
  showTranslationRequest,
} from "./lib/translation";
import { isTauriRuntime } from "./lib/platform";
import { Button } from "./components/ui/Button";
import { TranslationWindow } from "./components/translation/TranslationWindow";
import { VocabularyPage } from "./pages/VocabularyPage";
import { ReviewPage } from "./pages/ReviewPage";
import { SettingsPage } from "./pages/SettingsPage";

type Page = "vocabulary" | "review" | "settings";

const navItems: Array<{ page: Page; label: string; icon: JSX.Element }> = [
  { page: "vocabulary", label: "Vocabulary", icon: <BookOpen size={17} /> },
  { page: "review", label: "Review", icon: <Languages size={17} /> },
  { page: "settings", label: "Settings", icon: <Settings size={17} /> },
];

export default function App() {
  const params = useMemo(() => new URLSearchParams(window.location.search), []);
  const windowName = params.get("window");

  if (windowName === "float_bar" || windowName === "popup_card") {
    return <TranslationWindow />;
  }

  return <MainWindow />;
}

function MainWindow() {
  const [page, setPage] = useState<Page>("vocabulary");
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [words, setWords] = useState<WordEntry[]>([]);
  const [shortcutError, setShortcutError] = useState("");
  const settingsRef = useRef<AppSettings>(DEFAULT_SETTINGS);

  useEffect(() => {
    if (!settings) return;
    settingsRef.current = settings;
    void applyAppearanceSettings(settings).catch((error) => {
      console.error("Failed to apply appearance settings", error);
    });
  }, [settings]);

  useEffect(() => {
    refreshSettings();
    refreshWords();
  }, []);

  useEffect(() => {
    if (!isTauriRuntime()) return;

    returnEffect(
      listen("englist://shortcut-triggered", async () => {
        await translateSelection(settingsRef.current);
      }),
    );
  }, []);

  useEffect(() => {
    if (!isTauriRuntime()) return;

    returnEffect(
      listen("englist://cycle-display-mode", async () => {
        const currentSettings = settingsRef.current;
        const nextSettings = {
          ...currentSettings,
          displayMode: nextDisplayMode(currentSettings.displayMode),
        };
        await saveSettings(nextSettings);
        setSettings(nextSettings);
      }),
    );
  }, []);

  async function refreshSettings() {
    setSettings(await loadSettings());
  }

  async function refreshWords() {
    setWords(await listWords());
  }

  const handleSettingsChanged = useCallback(async (nextSettings: AppSettings) => {
    setSettings(nextSettings);
    if (isTauriRuntime()) {
      await emit("englist://settings-changed", nextSettings);
    }
  }, []);

  async function translateSelection(currentSettings: AppSettings) {
    setShortcutError("");

    try {
      const selectedText = await captureSelectedText();
      if (looksLikeSecret(selectedText)) {
        throw new Error("Selected text looks like an API key. Select a word or phrase instead.");
      }

      await showTranslationRequest(selectedText, currentSettings.displayMode);
    } catch (error) {
      const message = errorMessage(error, "Global translation failed.");
      setShortcutError(message);
      await showTranslationError(message, currentSettings.displayMode);
    }
  }

  const activeSettings = settings ?? DEFAULT_SETTINGS;

  return (
    <main className="app-shell">
      <div className="mx-auto grid max-w-7xl gap-6 px-4 py-5 md:grid-cols-[240px_1fr] md:px-6 lg:px-8">
        <aside className="md:sticky md:top-5 md:h-[calc(100vh-40px)]">
          <div className="rounded-lg border border-border bg-panel p-4">
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-md bg-accent text-accentForeground">
                <Wand2 size={20} />
              </div>
              <div>
                <h1 className="text-lg font-semibold">Englist Tool</h1>
                <p className="text-xs text-muted">{activeSettings.shortcut}</p>
              </div>
            </div>

            <nav className="mt-6 grid gap-2">
              {navItems.map((item) => (
                <Button
                  className="justify-start"
                  icon={item.icon}
                  key={item.page}
                  onClick={() => setPage(item.page)}
                  variant={page === item.page ? "primary" : "ghost"}
                >
                  {item.label}
                </Button>
              ))}
            </nav>
          </div>
        </aside>

        <section className="grid content-start gap-5">
          {shortcutError ? (
            <div className="rounded-md border border-danger/40 bg-danger/10 px-4 py-3 text-sm text-danger">
              {shortcutError}
            </div>
          ) : null}
          {page === "vocabulary" ? <VocabularyPage words={words} onWordsChanged={refreshWords} /> : null}
          {page === "review" ? <ReviewPage words={words} onWordsChanged={refreshWords} /> : null}
          {page === "settings" && settings ? (
            <SettingsPage settings={settings} onSettingsChanged={handleSettingsChanged} />
          ) : null}
          {page === "settings" && !settings ? (
            <div className="rounded-md border border-border bg-panel px-4 py-3 text-sm text-muted">
              Loading settings...
            </div>
          ) : null}
        </section>
      </div>
    </main>
  );
}

function returnEffect(cleanup: Promise<() => void>) {
  let unsubscribe: (() => void) | undefined;
  let didCleanup = false;
  cleanup.then((nextUnsubscribe) => {
    if (didCleanup) {
      nextUnsubscribe();
      return;
    }
    unsubscribe = nextUnsubscribe;
  });
  return () => {
    didCleanup = true;
    unsubscribe?.();
  };
}

function nextDisplayMode(mode: AppSettings["displayMode"]): AppSettings["displayMode"] {
  if (mode === "always_bar") return "auto_bar";
  if (mode === "auto_bar") return "popup_card";
  return "always_bar";
}

function looksLikeSecret(text: string) {
  const trimmed = text.trim();
  return /^sk-[A-Za-z0-9_-]{16,}$/.test(trimmed) || /^sk-[A-Za-z0-9_-]+/.test(trimmed);
}
