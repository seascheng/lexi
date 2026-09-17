import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { BookOpen, Brain, NotebookPen, PanelLeft, PanelLeftClose, Settings, Sparkles } from "lucide-react";
import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from "react";
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
import { cn } from "./lib/cn";
import { VocabularyPage } from "./pages/VocabularyPage";
import { ReviewPage } from "./pages/ReviewPage";
import { SettingsPage } from "./pages/SettingsPage";
import { ConfigsPage } from "./pages/ConfigsPage";
import { NotebookPage } from "./pages/NotebookPage";

type Page = "vocabulary" | "review" | "notebook" | "configs" | "settings";

const navItems: Array<{ page: Page; label: string; icon: JSX.Element; dividerBefore?: boolean }> = [
  { page: "vocabulary", label: "Vocabulary", icon: <BookOpen size={17} /> },
  { page: "review", label: "Review", icon: <Brain size={17} /> },
  { page: "notebook", label: "Notebook", icon: <NotebookPen size={17} /> },
  { page: "configs", label: "Configs", icon: <Sparkles size={17} />, dividerBefore: true },
  { page: "settings", label: "Settings", icon: <Settings size={17} /> },
];

export default function App() {
  return <MainWindow />;
}

function MainWindow() {
  const [page, setPage] = useState<Page>("vocabulary");
  const [sidebarCollapsed, setSidebarCollapsed] = useState(false);
  const [settings, setSettings] = useState<AppSettings | null>(null);
  const [words, setWords] = useState<WordEntry[]>([]);
  const settingsRef = useRef<AppSettings>(DEFAULT_SETTINGS);
  const didShowWindowRef = useRef(false);

  useEffect(() => {
    if (!settings) return;
    settingsRef.current = settings;
    void applyAppearanceSettings(settings).then(() => {
      // Show after the theme has been applied and the first frame painted,
      // so the window never flashes an empty shell (visible:false in tauri.conf.json).
      if (isTauriRuntime() && !didShowWindowRef.current) {
        didShowWindowRef.current = true;
        void revealMainWindow();
      }
    }).catch((error) => {
      console.error("Failed to apply appearance settings", error);
      if (isTauriRuntime() && !didShowWindowRef.current) {
        didShowWindowRef.current = true;
        void revealMainWindow();
      }
    });
    if (isTauriRuntime()) {
      void invoke("set_native_toolbar_theme", {
        theme: settings.theme,
        panelOpacity: settings.panelOpacity,
        panelBlur: settings.panelBlur,
      }).catch(
        (error) => {
          console.warn("Failed to sync native toolbar theme", error);
        },
      );
      void invoke("set_popup_shortcut", {
        shortcut: settings.popupShortcut,
      }).catch((error) => {
        console.warn("Failed to sync popup shortcut", error);
      });
      void invoke("set_launcher_shortcut", {
        shortcut: settings.launcherShortcut,
      }).catch((error) => {
        console.warn("Failed to sync launcher shortcut", error);
      });
      void invoke("set_clipboard_shortcut", {
        shortcut: settings.clipboardShortcut,
      }).catch((error) => {
        console.warn("Failed to sync clipboard shortcut", error);
      });
      void invoke("set_excluded_toolbar_apps", {
        apps: settings.excludedToolbarApps ?? [],
      }).catch((error) => {
        console.warn("Failed to sync excluded toolbar apps", error);
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
        className="grid min-h-screen items-stretch md:h-screen"
        style={{ gridTemplateColumns: `${sidebarWidth} 1fr` }}
      >
        <aside className="app-sidebar md:sticky md:top-0 md:h-screen">
          <div className={`flex h-full flex-col border-b border-border/30 transition-all duration-200 md:border-b-0 md:border-r ${sidebarCollapsed ? "py-4 px-2.5" : "p-4"}`}>
            <div className="flex items-center gap-2.5 px-1">
              <img src={logoUrl} alt="Lexi" className="app-logo h-7 w-7 shrink-0" />
              {!sidebarCollapsed && (
                <h1 className="truncate text-[15px] font-semibold tracking-tight">Lexi</h1>
              )}
            </div>

            <nav className="mt-4 grid gap-0.5">
              {navItems.map((item) => (
                <Fragment key={item.page}>
                  {item.dividerBefore && (
                    <div className="my-1.5 border-t border-border/30" />
                  )}
                  <button
                    aria-current={page === item.page ? "page" : undefined}
                    className={cn(
                      "flex h-7 items-center gap-2 rounded-md px-2 text-[13px] font-medium transition-colors",
                      sidebarCollapsed ? "justify-center px-0" : "",
                      page === item.page
                        ? "bg-strong/10 text-strong"
                        : "text-muted hover:bg-strong/5 hover:text-strong",
                    )}
                    onClick={() => setPage(item.page)}
                    title={sidebarCollapsed ? item.label : undefined}
                    type="button"
                  >
                    <span className={cn("shrink-0 [&>svg]:h-[15px] [&>svg]:w-[15px]")}>{item.icon}</span>
                    {!sidebarCollapsed && item.label}
                  </button>
                </Fragment>
              ))}
            </nav>

            <div className="mt-auto pt-2">
              <button
                className={cn(
                  "flex h-7 items-center gap-2 rounded-md text-[13px] font-medium text-muted transition-colors hover:bg-strong/5 hover:text-strong",
                  sidebarCollapsed ? "justify-center px-0 w-full" : "px-2",
                )}
                onClick={() => setSidebarCollapsed(!sidebarCollapsed)}
                type="button"
              >
                <span className="shrink-0 [&>svg]:h-[15px] [&>svg]:w-[15px]">
                  {sidebarCollapsed ? <PanelLeft size={15} /> : <PanelLeftClose size={15} />}
                </span>
                {!sidebarCollapsed && "Collapse"}
              </button>
            </div>
          </div>
        </aside>

        <section className="app-content flex flex-col overflow-hidden md:h-screen">
          <div className="min-h-0 flex-1 overflow-y-auto p-4 md:p-5">
            {pageContent}
          </div>
        </section>
      </div>
    </main>
  );
}

async function revealMainWindow() {
  const win = getCurrentWindow();
  // Wait for the activation-policy change (menu-bar-only) to settle:
  // switching to Accessory orders out windows shown before the flip.
  await new Promise((resolve) => window.setTimeout(resolve, 120));
  await win.show();
  // Safety net: if the policy flip landed after show(), re-show once.
  window.setTimeout(() => {
    void win.show().catch(() => {});
  }, 350);
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
