import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { BookOpen, Languages, Settings, Sparkles } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AppSettings, WordEntry } from "./types";
import logoUrl from "../logo.svg";
import { applyAppearanceSettings } from "./lib/appearance";
import { DEFAULT_SETTINGS } from "./lib/defaults";
import { listAiFeatures, listWords, loadSettings, loadToolbarTools, saveSettings } from "./lib/database";
import { syncNativeToolbar } from "./lib/nativeToolbar";
import { isTauriRuntime } from "./lib/platform";
import { Button } from "./components/ui/Button";
import { TranslationWindow } from "./components/translation/TranslationWindow";
import { VocabularyPage } from "./pages/VocabularyPage";
import { ReviewPage } from "./pages/ReviewPage";
import { SettingsPage } from "./pages/SettingsPage";
import { ConfigsPage } from "./pages/ConfigsPage";

type Page = "vocabulary" | "review" | "configs" | "settings";

const navItems: Array<{ page: Page; label: string; icon: JSX.Element }> = [
  { page: "vocabulary", label: "Expressions", icon: <BookOpen size={17} /> },
  { page: "review", label: "Review", icon: <Languages size={17} /> },
  { page: "configs", label: "Configs", icon: <Sparkles size={17} /> },
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
  const settingsRef = useRef<AppSettings>(DEFAULT_SETTINGS);

  useEffect(() => {
    if (!settings) return;
    settingsRef.current = settings;
    void applyAppearanceSettings(settings).catch((error) => {
      console.error("Failed to apply appearance settings", error);
    });
    if (isTauriRuntime()) {
      void invoke("set_native_toolbar_theme", { theme: settings.theme }).catch((error) => {
        console.warn("Failed to sync native toolbar theme", error);
      });
      void syncNativeToolbarFromSettings(settings);
    }
  }, [settings]);

  useEffect(() => {
    refreshSettings();
    refreshWords();
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

  useEffect(() => {
    if (!isTauriRuntime()) return;

    returnEffect(
      listen("englist://words-changed", async () => {
        await refreshWords();
      }),
    );
  }, []);

  async function refreshSettings() {
    setSettings(await loadSettings());
  }

  async function refreshWords() {
    setWords(await listWords());
  }

  async function syncNativeToolbarFromSettings(nextSettings: AppSettings) {
    const [features, tools] = await Promise.all([listAiFeatures(), loadToolbarTools()]);
    await syncNativeToolbar(nextSettings, features, tools);
  }

  const handleSettingsChanged = useCallback(async (nextSettings: AppSettings) => {
    setSettings(nextSettings);
    if (isTauriRuntime()) {
      await emit("englist://settings-changed", nextSettings);
    }
  }, []);

  const pageContent =
    page === "vocabulary" ? (
      <VocabularyPage words={words} onWordsChanged={refreshWords} />
    ) : page === "review" ? (
      <ReviewPage words={words} onWordsChanged={refreshWords} />
    ) : page === "configs" ? (
      <ConfigsPage />
    ) : page === "settings" && settings ? (
      <SettingsPage settings={settings} onSettingsChanged={handleSettingsChanged} />
    ) : (
      <div className="rounded-md border border-border bg-panel px-4 py-3 text-sm text-muted">
        Loading settings...
      </div>
    );

  return (
    <main className="app-shell">
      <div className="mx-auto grid min-h-screen max-w-7xl items-stretch gap-4 px-3 py-4 md:grid-cols-[216px_1fr] md:px-4 lg:px-5">
        <aside className="md:sticky md:top-4 md:h-[calc(100vh-32px)]">
          <div className="flex h-full flex-col rounded-lg border border-border bg-panel p-3">
            <div className="flex items-center gap-2.5 px-1">
              <img src={logoUrl} alt="Lexicon" className="h-8 w-8" />
              <h1 className="truncate text-base font-semibold">Lexicon</h1>
            </div>

            <nav className="mt-5 grid gap-1.5">
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

        <section className="flex h-[calc(100vh-32px)] min-h-[calc(100vh-32px)] flex-col gap-3 overflow-hidden rounded-lg border border-border bg-panel p-3">
          <div className="min-h-0 flex-1 overflow-hidden">{pageContent}</div>
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
