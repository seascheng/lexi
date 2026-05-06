import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { BookOpen, Eye, NotebookPen, PanelLeft, PanelLeftClose, Settings, Sparkles } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { AppSettings, WordEntry } from "./types";
import logoUrl from "../logo.svg";
import { applyAppearanceSettings } from "./lib/appearance";
import { DEFAULT_SETTINGS } from "./lib/defaults";
import {
  listAiFeatures,
  listWords,
  loadSettings,
  loadToolbarTools,
} from "./lib/database";
import { syncNativeToolbar } from "./lib/nativeToolbar";
import { isTauriRuntime } from "./lib/platform";
import { Button } from "./components/ui/Button";
import { TranslationWindow } from "./components/translation/TranslationWindow";
import { VocabularyPage } from "./pages/VocabularyPage";
import { ReviewPage } from "./pages/ReviewPage";
import { SettingsPage } from "./pages/SettingsPage";
import { ConfigsPage } from "./pages/ConfigsPage";
import { NotebookPage } from "./pages/NotebookPage";

type Page = "vocabulary" | "review" | "notebook" | "configs" | "settings";

const navItems: Array<{ page: Page; label: string; icon: JSX.Element }> = [
  { page: "vocabulary", label: "Vocabulary", icon: <BookOpen size={17} /> },
  { page: "review", label: "Review", icon: <Eye size={17} /> },
  { page: "notebook", label: "Notebook", icon: <NotebookPen size={17} /> },
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
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
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
      void invoke("set_native_toolbar_theme", { theme: settings.theme }).catch(
        (error) => {
          console.warn("Failed to sync native toolbar theme", error);
        },
      );
      void invoke("set_popup_shortcut", {
        shortcut: settings.popupShortcut,
      }).catch((error) => {
        console.warn("Failed to sync popup shortcut", error);
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
      listen("lexi://words-changed", async () => {
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
    const [features, tools] = await Promise.all([
      listAiFeatures(),
      loadToolbarTools(),
    ]);
    await syncNativeToolbar(nextSettings, features, tools);
  }

  const handleSettingsChanged = useCallback(
    async (nextSettings: AppSettings) => {
      setSettings(nextSettings);
      if (isTauriRuntime()) {
        await emit("lexi://settings-changed", nextSettings);
      }
    },
    [],
  );

  const pageContent =
    page === "vocabulary" ? (
      <VocabularyPage words={words} onWordsChanged={refreshWords} />
    ) : page === "review" ? (
      <ReviewPage words={words} onWordsChanged={refreshWords} />
    ) : page === "notebook" ? (
      <NotebookPage />
    ) : page === "configs" ? (
      <ConfigsPage />
    ) : page === "settings" && settings ? (
      <SettingsPage
        settings={settings}
        onSettingsChanged={handleSettingsChanged}
      />
    ) : (
      <div className="rounded-md border border-border bg-panel px-4 py-3 text-sm text-muted">
        Loading settings...
      </div>
    );

  const sidebarWidth = sidebarCollapsed ? "52px" : "180px";

  return (
    <main className="app-shell">
      <div
        className="mx-auto grid min-h-screen max-w-7xl items-stretch bg-panel md:h-screen"
        style={{ gridTemplateColumns: `${sidebarWidth} 1fr` }}
      >
        <aside className="md:sticky md:top-0 md:h-screen">
          <div className="flex h-full flex-col border-b border-border/50 p-4 transition-all duration-200 md:border-b-0 md:border-r">
            <div className="flex items-center gap-2.5 px-1">
              <img src={logoUrl} alt="Lexi" className="app-logo h-8 w-8 shrink-0" />
              {!sidebarCollapsed && (
                <h1 className="truncate font-mono text-base font-bold tracking-widest">Lexi</h1>
              )}
            </div>

            <nav className="mt-5 grid gap-1.5">
              {navItems.map((item) => (
                <Button
                  className="justify-start"
                  icon={item.icon}
                  key={item.page}
                  onClick={() => setPage(item.page)}
                  variant={page === item.page ? "primary" : "ghost"}
                  title={sidebarCollapsed ? item.label : undefined}
                >
                  {!sidebarCollapsed && item.label}
                </Button>
              ))}
            </nav>

            <div className="mt-auto pt-2">
              <Button
                className={sidebarCollapsed ? "justify-center" : "justify-start"}
                icon={sidebarCollapsed ? <PanelLeft size={17} /> : <PanelLeftClose size={17} />}
                variant="ghost"
                onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
              >
                {!sidebarCollapsed && "Collapse"}
              </Button>
            </div>
          </div>
        </aside>

        <section className="flex flex-col overflow-hidden md:h-screen">
          <div className="min-h-0 flex-1 overflow-hidden p-4 md:p-5">
            {pageContent}
          </div>
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
