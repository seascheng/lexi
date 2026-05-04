import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AlertCircle, Clipboard, Loader2, Save, X } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AiFeature, AiFeatureIcon, AiRunResult, AppSettings, LearningEntryInput, LearningEntryType, Panel, ToolbarTool, WordEntry } from "../../types";
import { copyText, runAiFeature, speakText } from "../../lib/ai";
import { applyAppearanceSettings } from "../../lib/appearance";
import { addWord, addNote, listAiFeatures, listPanels, listWords, loadSettings, loadToolbarTools, savePopupPosition, savePopupSize, saveSettings } from "../../lib/database";
import { errorMessage } from "../../lib/errors";
import { FeatureIcon } from "../../lib/featureIcons";
import { syncNativeToolbar } from "../../lib/nativeToolbar";
import { Button } from "../ui/Button";
import { FloatingFrame, type PopupResizeStart } from "./FloatingFrame";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";
import { registerPanel, getPanelComponent } from "../../lib/panelRegistry";
import { ReviewPanel } from "./ReviewPanel";
import { NotesPanel } from "./NotesPanel";

const DEFAULT_POPUP_SIZE = 360;

registerPanel("review", ReviewPanel);
registerPanel("notes", NotesPanel);

type WorkspaceRunStatus = "loading" | "ready" | "error";
type WorkspaceRunKind = "feature";

interface WorkspaceRun {
  id: string;
  kind: WorkspaceRunKind;
  title: string;
  featureId?: string;
  icon?: AiFeatureIcon;
  inputText: string;
  status: WorkspaceRunStatus;
  result?: AiRunResult;
  message?: string;
  learningEntry?: LearningEntryInput;
  saved?: boolean;
  createdAt: number;
}

interface RequestPayload {
  text: string;
  featureId?: string;
}

interface ErrorPayload {
  message: string;
  featureId?: string;
}

interface ReadyPayload {
  result: AiRunResult;
  feature: AiFeature;
  text: string;
}

export function TranslationWindow() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [tools, setTools] = useState<ToolbarTool[]>([]);
  const [inputText, setInputText] = useState("");
  const [runs, setRuns] = useState<WorkspaceRun[]>([]);
  const [activeRunId, setActiveRunId] = useState("");
  const [isPinned, setIsPinned] = useState(true);
  const [panels, setPanels] = useState<Panel[]>([]);
  const [activePanelId, setActivePanelId] = useState<string>("translate");
  const [words, setWords] = useState<WordEntry[]>([]);
  const positionSaveTimerRef = useRef<number>();
  const sizeSaveTimerRef = useRef<number>();
  const shellRef = useRef<HTMLElement>(null);
  const featuresRef = useRef<AiFeature[]>([]);
  const inputTextRef = useRef("");
  const runsRef = useRef<WorkspaceRun[]>([]);
  const isPinnedRef = useRef(true);
  const activePanelIdRef = useRef(activePanelId);

  useEffect(() => { activePanelIdRef.current = activePanelId; }, [activePanelId]);
  const params = useMemo(() => new URLSearchParams(window.location.search), []);
  const windowName = params.get("window");
  const isBar = windowName === "float_bar";
  const actionFeatures = useMemo(
    () => features.filter((feature) => feature.panelEnabled).sort((a, b) => a.panelSortOrder - b.panelSortOrder),
    [features],
  );

  type PanelItem = { kind: "tool"; tool: ToolbarTool } | { kind: "feature"; feature: AiFeature };

  const panelItems = useMemo<PanelItem[]>(() => {
    const items: PanelItem[] = [
      ...tools.filter((t) => t.panelEnabled).map((t) => ({ kind: "tool" as const, tool: t })),
      ...features.filter((f) => f.panelEnabled).map((f) => ({ kind: "feature" as const, feature: f })),
    ];
    return items.sort((a, b) => {
      const orderA = a.kind === "tool" ? a.tool.panelSortOrder : a.feature.panelSortOrder;
      const orderB = b.kind === "tool" ? b.tool.panelSortOrder : b.feature.panelSortOrder;
      return orderA - orderB;
    });
  }, [tools, features]);

  const defaultFeature = actionFeatures[0];
  const latestRun = runs[0];
  const activeRun = runs.find((run) => run.id === activeRunId) ?? runs[0];

  useEffect(() => {
    featuresRef.current = features;
  }, [features]);

  useEffect(() => {
    inputTextRef.current = inputText;
  }, [inputText]);

  useEffect(() => {
    runsRef.current = runs;
  }, [runs]);

  useEffect(() => {
    isPinnedRef.current = isPinned;
    void getCurrentWindow().setAlwaysOnTop(isPinned).catch((error) => {
      console.warn("Failed to update popup pin state", error);
    });
  }, [isPinned]);

  useEffect(() => {
    void initializePopup();

    const cleanups = [
      listen<RequestPayload>("englist://ai-request", (event) => {
        void runActiveFeature(event.payload.text, event.payload.featureId);
      }),
      listen<RequestPayload>("englist://ai-loading", (event) => {
        const feature = currentActionFeature(event.payload.featureId);
        if (!feature) return;
        const text = event.payload.text.trim();
        if (text) setInputText(text);
        addWorkspaceRun({
          kind: "feature",
          title: feature.name,
          featureId: feature.id,
          icon: feature.icon,
          inputText: text,
          status: "loading",
        });
      }),
      listen<ErrorPayload>("englist://ai-error", (event) => {
        const feature = currentActionFeature(event.payload.featureId);
        addWorkspaceRun({
          kind: "feature",
          title: feature?.name ?? "AI action",
          featureId: feature?.id,
          icon: feature?.icon,
          inputText: inputTextRef.current,
          status: "error",
          message: event.payload.message,
        });
      }),
      listen<ReadyPayload>("englist://ai-ready", (event) => {
        const text = event.payload.text.trim();
        if (text) setInputText(text);
        addWorkspaceRun({
          kind: "feature",
          title: event.payload.feature.name,
          featureId: event.payload.feature.id,
          icon: event.payload.feature.icon,
          inputText: text,
          status: "ready",
          result: event.payload.result,
        });
      }),
      listen<AppSettings>("englist://settings-changed", (event) => {
        void applyAppearanceSettings(event.payload);
        void syncNativeToolbarActions(featuresRef.current);
      }),
      listen("englist://features-changed", () => {
        void reloadFeatures();
      }),
      listen("englist://popup-shown", () => {
        resetPopupWorkspace();
      }),
      listen("englist://words-changed", async () => {
        const refreshed = await listWords();
        setWords(refreshed);
      }),
      listen<{ text: string }>("englist://save-note", async (event) => {
        const isPopup = new URLSearchParams(window.location.search).get("window") === "popup_card";
        if (!isPopup) return;
        await addNote({ content: event.payload.text });
        await emit("englist://notes-changed");
      }),
    ];

    return () => {
      cleanups.forEach((cleanup) => {
        cleanup.then((unsubscribe) => unsubscribe());
      });
    };
  }, []);

  useEffect(() => {
    if (isBar) return;

    const currentWindow = getCurrentWindow();
    let unsubscribe: (() => void) | undefined;
    let didCleanup = false;

    currentWindow
      .onMoved((event) => {
        if (positionSaveTimerRef.current) {
          window.clearTimeout(positionSaveTimerRef.current);
        }

        positionSaveTimerRef.current = window.setTimeout(() => {
          void savePopupPosition({ x: event.payload.x, y: event.payload.y });
        }, 250);
      })
      .then((nextUnsubscribe) => {
        if (didCleanup) {
          nextUnsubscribe();
          return;
        }
        unsubscribe = nextUnsubscribe;
      });

    return () => {
      didCleanup = true;
      unsubscribe?.();
      if (positionSaveTimerRef.current) {
        window.clearTimeout(positionSaveTimerRef.current);
      }
    };
  }, [isBar]);

  useEffect(() => {
    if (isBar) return;

    const currentWindow = getCurrentWindow();
    let unsubscribe: (() => void) | undefined;
    let didCleanup = false;

    currentWindow
      .onResized(() => {
        if (sizeSaveTimerRef.current) {
          window.clearTimeout(sizeSaveTimerRef.current);
        }

        sizeSaveTimerRef.current = window.setTimeout(() => {
          void savePopupSize({ width: window.innerWidth, height: window.innerHeight });
        }, 250);
      })
      .then((nextUnsubscribe) => {
        if (didCleanup) {
          nextUnsubscribe();
          return;
        }
        unsubscribe = nextUnsubscribe;
      });

    return () => {
      didCleanup = true;
      unsubscribe?.();
      if (sizeSaveTimerRef.current) {
        window.clearTimeout(sizeSaveTimerRef.current);
      }
    };
  }, [isBar]);

  useEffect(() => {
    const currentWindow = getCurrentWindow();
    let unsubscribe: (() => void) | undefined;
    let didCleanup = false;

    currentWindow
      .onFocusChanged((event) => {
        if (!event.payload && !isPinnedRef.current) {
          void currentWindow.hide();
        }
      })
      .then((nextUnsubscribe) => {
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
  }, []);

  useEffect(() => {
    if (
      isPinned ||
      !latestRun ||
      !isBar ||
      latestRun.status === "loading"
    ) {
      return;
    }

    const timeoutId = window.setTimeout(() => {
      getCurrentWindow().hide();
    }, 5000);
    return () => window.clearTimeout(timeoutId);
  }, [latestRun, isPinned]);

  useEffect(() => {
    if (isBar) return;
    const frame = shellRef.current?.querySelector<HTMLElement>(".translation-frame");
    const page = shellRef.current?.querySelector<HTMLElement>(".translation-tab-page");
    const content = shellRef.current?.querySelector<HTMLElement>(".translation-content");
    if (!frame || !page || !content) return;

    let resizeTimer: number | undefined;
    const scheduleResize = () => {
      if (resizeTimer) window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        void resizePopupToContent(frame, page, content);
      }, 60);
    };
    const observer = new ResizeObserver(scheduleResize);

    observer.observe(page);
    observer.observe(content);
    Array.from(content.children).forEach((child) => observer.observe(child));
    scheduleResize();

    return () => {
      observer.disconnect();
      if (resizeTimer) window.clearTimeout(resizeTimer);
    };
  }, [inputText, isBar, runs]);

  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") getCurrentWindow().hide();
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, []);

  async function initializePopup() {
    const [loadedSettings, nextFeatures, nextTools, loadedPanels, loadedWords] = await Promise.all([loadSettings(), listAiFeatures(), loadToolbarTools(), listPanels(), listWords()]);
    await applyAppearanceSettings(loadedSettings);
    setTools(nextTools);
    applyFeatureList(nextFeatures);
    setPanels(loadedPanels);
    setWords(loadedWords);

    if (loadedSettings.activePanelId) {
      const enabledIds = loadedPanels.filter(p => p.enabled).map(p => p.id);
      if (enabledIds.includes(loadedSettings.activePanelId)) {
        setActivePanelId(loadedSettings.activePanelId);
      }
    }
  }

  async function reloadFeatures() {
    applyFeatureList(await listAiFeatures());
  }

  function applyFeatureList(nextFeatures: AiFeature[]) {
    setFeatures(nextFeatures);
    featuresRef.current = nextFeatures;
    void syncNativeToolbarActions(nextFeatures);
  }

  async function syncNativeToolbarActions(nextFeatures: AiFeature[]) {
    const nextTools = await loadToolbarTools();
    setTools(nextTools);

    const settings = await loadSettings();
    await syncNativeToolbar(settings, nextFeatures, nextTools);
  }

  function submitDefaultFeature(event: FormEvent) {
    event.preventDefault();
    if (!defaultFeature) return;
    void runFeature(inputText, defaultFeature);
  }

  async function runActiveFeature(rawText: string, featureId?: string) {
    const feature = await loadCurrentActionFeature(featureId);
    if (!feature) {
      addWorkspaceRun({
        kind: "feature",
        title: "AI action",
        inputText: rawText,
        status: "error",
        message: "No enabled AI actions are available.",
      });
      return;
    }

    await runFeature(rawText, feature);
  }

  async function runFeature(rawText: string, feature: AiFeature) {
    const text = rawText.trim();
    if (!text) return;

    setInputText(text);
    const runId = addWorkspaceRun({
      kind: "feature",
      title: feature.name,
      featureId: feature.id,
      icon: feature.icon,
      inputText: text,
      status: "loading",
    });

    try {
      const settings = await loadSettings();
      await applyAppearanceSettings(settings);
      const result = await runAiFeature(text, feature, settings);
      let saved = false;

      if (feature.kind === "translation" && feature.autoSaveToVocabulary && isSingleWordTranslation(text, result)) {
        await addWord(wordLearningEntry(text, result));
        await emit("englist://words-changed");
        saved = true;
      }

      updateWorkspaceRun(runId, {
        status: "ready",
        result,
        saved,
      });
    } catch (error) {
      updateWorkspaceRun(runId, {
        status: "error",
        message: errorMessage(error, `${feature.name} failed.`),
      });
    }
  }

  async function loadCurrentActionFeature(featureId?: string) {
    const loadedFeatures = featuresRef.current.length > 0 ? featuresRef.current : await listAiFeatures();
    if (featuresRef.current.length === 0) {
      setFeatures(loadedFeatures);
      featuresRef.current = loadedFeatures;
    }

    return currentActionFeature(featureId);
  }

  function currentActionFeature(featureId?: string) {
    const enabled = featuresRef.current.filter((feature) => feature.enabled);
    const normalizedFeatureId = featureId?.toLowerCase();
    return (
      enabled.find((feature) => feature.id === featureId) ??
      enabled.find((feature) => featureAliasMatches(feature, normalizedFeatureId)) ??
      enabled.find((feature) => feature.id === runsRef.current[0]?.featureId) ??
      enabled[0]
    );
  }

  function addWorkspaceRun(run: Omit<WorkspaceRun, "id" | "createdAt">) {
    const id = newRunId();
    const nextRun: WorkspaceRun = {
      ...run,
      id,
      createdAt: Date.now(),
    };

    setActiveRunId(id);
    setRuns((currentRuns) => {
      const nextRuns = [nextRun, ...currentRuns].slice(0, 12);
      runsRef.current = nextRuns;
      return nextRuns;
    });
    return id;
  }

  function updateWorkspaceRun(runId: string, update: Partial<WorkspaceRun>) {
    setRuns((currentRuns) => {
      const nextRuns = currentRuns.map((run) => (run.id === runId ? { ...run, ...update } : run));
      runsRef.current = nextRuns;
      return nextRuns;
    });
  }

  function dismissWorkspaceRun(runId: string) {
    setRuns((currentRuns) => {
      const nextRuns = currentRuns.filter((run) => run.id !== runId);
      runsRef.current = nextRuns;
      setActiveRunId((currentActiveRunId) => {
        if (currentActiveRunId !== runId) return currentActiveRunId;
        return nextRuns[0]?.id ?? "";
      });
      return nextRuns;
    });
  }

  function clearWorkspaceRuns() {
    runsRef.current = [];
    setRuns([]);
    setActiveRunId("");
  }

  function resetPopupWorkspace() {
    clearWorkspaceRuns();
    setActivePanelId("translate");
    if (isBar) return;

    void getCurrentWindow().setSize(new LogicalSize(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE)).catch((error) => {
      console.warn("Failed to reset popup size", error);
    });
  }

  function handlePanelChange(id: string) {
    setActivePanelId(id);
    void loadSettings().then((s) => saveSettings({ ...s, activePanelId: id }));
  }

  // Global keyboard handler via document event listener (not React onKeyDown)
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      const enabledPanels = panels.filter(p => p.enabled).sort((a, b) => a.sortOrder - b.sortOrder);
      if (enabledPanels.length === 0) return;
      const tag = (e.target as HTMLElement).tagName;
      const inInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";

      // Tab cycles panels
      if (e.key === "Tab" && !inInput) {
        e.preventDefault();
        e.stopPropagation();
        const idx = enabledPanels.findIndex(p => p.id === activePanelIdRef.current);
        const next = e.shiftKey
          ? (idx - 1 + enabledPanels.length) % enabledPanels.length
          : (idx + 1) % enabledPanels.length;
        handlePanelChange(enabledPanels[next].id);
        return;
      }

      // Arrow keys and Enter: prevent default only (panels handle via own listeners)
      if (["ArrowUp", "ArrowDown", "Enter"].includes(e.key) && !inInput) {
        e.preventDefault();
        e.stopPropagation();
      }
    }

    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [panels]);

  async function hidePopup() {
    await getCurrentWindow().hide();
  }

  async function runFeatureFromInput(feature: AiFeature) {
    const text = inputTextRef.current.trim();
    if (!text) {
      addWorkspaceRun({
        kind: "feature",
        title: feature.name,
        featureId: feature.id,
        icon: feature.icon,
        inputText: "",
        status: "error",
        message: "Enter text first.",
      });
      return;
    }

    await runFeature(text, feature);
  }

  async function handleToolAction(toolId: string) {
    const text = inputTextRef.current.trim();
    if (!text) return;
    const tool = tools.find((t) => t.id === toolId);
    switch (toolId) {
      case "copy":
        await copyText(text);
        break;
      case "search": {
        const encoded = encodeURIComponent(text);
        let url: string;
        const engine = (tool?.config?.engine as string) ?? "google";
        if (engine === "bing") url = `https://www.bing.com/search?q=${encoded}`;
        else if (engine === "duckduckgo") url = `https://duckduckgo.com/?q=${encoded}`;
        else if (engine === "custom") url = ((tool?.config?.customUrl as string) || "").replace("{query}", encoded);
        else url = `https://www.google.com/search?q=${encoded}`;
        window.open(url, "_blank");
        break;
      }
      case "read":
        await speakText(text);
        break;
      case "note":
        await addNote({ content: text });
        await emit("englist://notes-changed");
        break;
    }
  }

  async function saveLearningEntry(runId: string) {
    const run = runsRef.current.find((item) => item.id === runId);
    if (!run?.learningEntry || run.saved) return;

    await addWord(run.learningEntry);
    await emit("englist://words-changed");
    updateWorkspaceRun(runId, { saved: true });
  }

  function updateRunEntryType(runId: string, entryType: LearningEntryType) {
    const run = runsRef.current.find((item) => item.id === runId);
    if (!run?.learningEntry) return;
    if (run.saved) return;

    updateWorkspaceRun(runId, {
      saved: false,
      learningEntry: {
        ...run.learningEntry,
        entry_type: entryType,
      },
    });
  }

  return (
    <main className="translation-window-shell h-screen bg-transparent" ref={shellRef}>
      <FloatingFrame
        isPinned={isPinned}
        panels={panels.filter(p => p.enabled).sort((a, b) => a.sortOrder - b.sortOrder)}
        activePanelId={activePanelId}
        onPanelChange={handlePanelChange}
        onClose={hidePopup}
        onStartResize={startWindowResize}
        onTogglePin={() => setIsPinned((currentIsPinned) => !currentIsPinned)}
      >
        {activePanelId === "translate" ? (
          <WorkspacePage
            actionFeatures={actionFeatures}
            activeRun={activeRun}
            activeRunId={activeRunId}
            defaultFeature={defaultFeature}
            inputText={inputText}
            panelItems={panelItems}
            runs={runs}
            onDismissRun={dismissWorkspaceRun}
            onEntryTypeChange={updateRunEntryType}
            onClearRuns={clearWorkspaceRuns}
            onInputChange={setInputText}
            onRunFeatureInput={(feature) => void runFeatureFromInput(feature)}
            onSaveLearningEntry={saveLearningEntry}
            onToolAction={(toolId) => void handleToolAction(toolId)}
            onSelectRun={setActiveRunId}
            onSubmitDefault={submitDefaultFeature}
          />
        ) : (() => {
          const PanelComponent = getPanelComponent(activePanelId);
          return PanelComponent ? (
            <PanelComponent
              words={words}
              onWordsChanged={() => listWords().then(setWords)}
              isPinned={isPinned}
            />
          ) : null;
        })()}
      </FloatingFrame>
    </main>
  );
}

async function startWindowDrag() {
  await getCurrentWindow().startDragging();
}

async function startWindowResize({ direction }: PopupResizeStart) {
  await invoke("start_popup_resize", { direction }).catch((error) => {
    console.warn("Failed to start popup resize", error);
  });
}

async function resizePopupToContent(frame: HTMLElement, page: HTMLElement, content: HTMLElement) {
  const frameTop = frame.getBoundingClientRect().top;
  const pageTop = page.getBoundingClientRect().top - frameTop;
  const pageHeight = naturalContentHeight(page);
  const contentOverflow = Math.max(0, naturalContentHeight(content) - content.clientHeight);
  const targetHeight = clamp(Math.ceil(pageTop + pageHeight + contentOverflow + 18), 360, 900);
  if (Math.abs(window.innerHeight - targetHeight) < 8) return;

  await invoke("set_popup_height", { height: targetHeight }).catch((error) => {
    console.warn("Failed to auto-size popup", error);
  });
}

function clamp(value: number, min: number, max: number) {
  return Math.min(max, Math.max(min, value));
}

function naturalContentHeight(content: HTMLElement) {
  const children = Array.from(content.children) as HTMLElement[];
  if (children.length === 0) return content.scrollHeight;

  const contentTop = content.getBoundingClientRect().top;
  const bottom = children.reduce((maxBottom, child) => {
    const rect = child.getBoundingClientRect();
    return Math.max(maxBottom, rect.bottom - contentTop);
  }, 0);

  return Math.max(content.scrollHeight, Math.ceil(bottom + contentPaddingY(content)));
}

function contentPaddingY(content: HTMLElement) {
  const style = window.getComputedStyle(content);
  return parseFloat(style.paddingTop) + parseFloat(style.paddingBottom);
}

interface WorkspacePageProps {
  actionFeatures: AiFeature[];
  activeRun?: WorkspaceRun;
  activeRunId: string;
  defaultFeature?: AiFeature;
  inputText: string;
  panelItems: Array<{ kind: "tool"; tool: ToolbarTool } | { kind: "feature"; feature: AiFeature }>;
  runs: WorkspaceRun[];
  onClearRuns: () => void;
  onDismissRun: (runId: string) => void;
  onEntryTypeChange: (runId: string, entryType: LearningEntryType) => void;
  onInputChange: (value: string) => void;
  onRunFeatureInput: (feature: AiFeature) => void;
  onSaveLearningEntry: (runId: string) => void | Promise<void>;
  onToolAction: (toolId: string) => void;
  onSelectRun: (runId: string) => void;
  onSubmitDefault: (event: FormEvent) => void;
}

function WorkspacePage({
  actionFeatures,
  activeRun,
  activeRunId,
  defaultFeature,
  inputText,
  panelItems,
  runs,
  onClearRuns,
  onDismissRun,
  onEntryTypeChange,
  onInputChange,
  onRunFeatureInput,
  onSaveLearningEntry,
  onToolAction,
  onSelectRun,
  onSubmitDefault,
}: WorkspacePageProps) {
  return (
    <div className="translation-tab-page flex min-h-0 flex-col gap-2 pt-2">
      <section className="translation-action-area shrink-0">
        <AiForm
          defaultFeature={defaultFeature}
          inputText={inputText}
          panelItems={panelItems}
          runs={runs}
          onInputChange={onInputChange}
          onRunFeatureInput={onRunFeatureInput}
          onToolAction={onToolAction}
          onSubmit={onSubmitDefault}
        />
      </section>
      <section
        className="translation-content overflow-y-auto"
      >
        {runs.length === 0 ? <div className="p-2.5"><IdleState hasActions={actionFeatures.length > 0} /></div> : null}
        {runs.length > 0 && activeRun ? (
          <>
            <RunTabs
              activeRunId={activeRunId || activeRun.id}
              runs={runs}
              onClearRuns={onClearRuns}
              onDismissRun={onDismissRun}
              onSelectRun={onSelectRun}
            />
            <WorkspaceRunCard
              run={activeRun}
              onEntryTypeChange={(entryType) => onEntryTypeChange(activeRun.id, entryType)}
              onSave={() => void onSaveLearningEntry(activeRun.id)}
            />
          </>
        ) : null}
      </section>
    </div>
  );
}

function RunTabs({
  activeRunId,
  runs,
  onClearRuns,
  onDismissRun,
  onSelectRun,
}: {
  activeRunId: string;
  runs: WorkspaceRun[];
  onClearRuns: () => void;
  onDismissRun: (runId: string) => void;
  onSelectRun: (runId: string) => void;
}) {
  return (
    <div className="sticky top-0 z-10 flex min-h-9 items-end gap-1 border-b border-strong/10 px-1 pt-1">
      <div className="flex min-w-0 flex-1 gap-0.5 overflow-x-auto">
        {runs.map((run) => (
          <button
            className={`group flex h-8 max-w-[150px] shrink-0 items-center gap-1.5 rounded-t-md px-2 text-left text-xs transition ${
              run.id === activeRunId
                ? "bg-panel/85 text-strong"
                : "text-muted hover:bg-panel/45 hover:text-strong"
            }`}
            key={run.id}
            onClick={() => onSelectRun(run.id)}
            title={`${run.title}: ${run.inputText}`}
            type="button"
          >
            <span className={run.status === "loading" ? "opacity-50" : ""}><FeatureIcon icon={run.icon ?? "wand"} size={13} /></span>
            <span className="truncate">{run.title}</span>
            <span
              aria-label="Close result"
              className="ml-0.5 grid h-4 w-4 shrink-0 place-items-center rounded text-muted hover:bg-surface/80 hover:text-strong"
              onClick={(event) => {
                event.preventDefault();
                event.stopPropagation();
                onDismissRun(run.id);
              }}
              role="button"
              tabIndex={0}
              title="Close result"
            >
              <X size={11} />
            </span>
          </button>
        ))}
      </div>
      <Button
        aria-label="Close all results"
        className="h-8 min-h-8 shrink-0 rounded-t-md rounded-b-none px-2 text-xs hover:bg-strong/12"
        icon={<X size={13} />}
        onClick={onClearRuns}
        title="Close all results"
        type="button"
        variant="ghost"
      >
        All
      </Button>
    </div>
  );
}

interface AiFormProps {
  defaultFeature?: AiFeature;
  inputText: string;
  panelItems: Array<{ kind: "tool"; tool: ToolbarTool } | { kind: "feature"; feature: AiFeature }>;
  runs: WorkspaceRun[];
  onInputChange: (value: string) => void;
  onRunFeatureInput: (feature: AiFeature) => void;
  onToolAction: (toolId: string) => void;
  onSubmit: (event: FormEvent) => void;
}

function AiForm({
  defaultFeature,
  inputText,
  panelItems,
  runs,
  onInputChange,
  onRunFeatureInput,
  onToolAction,
  onSubmit,
}: AiFormProps) {
  function resizeTextarea(element: HTMLTextAreaElement) {
    element.style.height = "auto";
    element.style.height = `${Math.min(140, element.scrollHeight)}px`;
  }

  const textareaRef = useRef<HTMLTextAreaElement>(null);

  useEffect(() => {
    if (textareaRef.current) resizeTextarea(textareaRef.current);
  }, [inputText]);

  return (
    <form className="grid gap-1.5" onSubmit={onSubmit}>
      <div className="translation-form flex w-full items-end rounded-lg border border-strong/10 bg-input p-1 shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]">
        <textarea
          className="max-h-[140px] min-h-8 min-w-0 flex-1 resize-none rounded-md border-0 bg-transparent px-2 py-1.5 text-sm leading-5 text-strong outline-none placeholder:text-muted"
          onChange={(event) => {
            onInputChange(event.target.value);
            resizeTextarea(event.currentTarget);
          }}
          onInput={(event) => resizeTextarea(event.currentTarget)}
          placeholder="Enter text"
          ref={textareaRef}
          rows={1}
          value={inputText}
        />
        <div className="ml-1 flex max-w-[52%] shrink-0 items-end overflow-x-auto rounded-md border border-strong/10 bg-surface/45">
          {panelItems.map((item) => {
            if (item.kind === "tool") {
              return (
                <Button
                  aria-label={`${item.tool.name} input text`}
                  className="h-8 min-h-8 w-8 shrink-0 rounded-none border-r border-strong/10 p-0"
                  disabled={!inputText.trim()}
                  icon={<FeatureIcon icon={item.tool.icon} size={15} />}
                  key={item.tool.id}
                  onClick={() => onToolAction(item.tool.id)}
                  title={`${item.tool.name} input text`}
                  type="button"
                  variant="ghost"
                />
              );
            }
            const isLoading = runs.some((run) => run.status === "loading" && run.featureId === item.feature.id && run.kind === "feature");
            return (
              <Button
                aria-label={`${item.feature.name} input text`}
                className="h-8 min-h-8 w-8 shrink-0 rounded-none border-r border-strong/10 p-0"
                disabled={isLoading || !inputText.trim()}
                icon={<FeatureIcon icon={item.feature.icon} size={15} />}
                key={item.feature.id}
                onClick={() => onRunFeatureInput(item.feature)}
                title={`${item.feature.name} input text`}
                type="button"
                variant="ghost"
              />
            );
          })}
        </div>
      </div>
    </form>
  );
}

function IdleState({ hasActions }: { hasActions: boolean }) {
  return (
    <p className="text-sm text-muted">
      {hasActions ? "Enter text, then choose an action." : "No enabled AI actions."}
    </p>
  );
}

function WorkspaceRunCard({
  run,
  onEntryTypeChange,
  onSave,
}: {
  run: WorkspaceRun;
  onEntryTypeChange: (entryType: LearningEntryType) => void;
  onSave: () => void;
}) {
  return (
    <article className="grid min-w-0 gap-2 p-2.5">
      {run.status === "loading" ? <LoadingRun title={run.title} /> : null}
      {run.status === "error" ? <ErrorRun title={run.title} message={run.message ?? "Action failed."} /> : null}
      {run.status === "ready" && run.result ? (
        <>
          <div className="p-2">
            <MarkdownRenderer content={run.result.outputText} />
          </div>
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            {run.learningEntry ? (
              <EntryTypeTags
                disabled={run.saved}
                entryType={run.learningEntry.entry_type ?? "phrase"}
                onEntryTypeChange={onEntryTypeChange}
              />
            ) : <span />}
            <div className="flex justify-end gap-1.5">
              <Button
                aria-label="Copy result"
                className="h-7 min-h-7 px-2 text-xs"
                icon={<Clipboard size={14} />}
                onClick={() => copyText(run.result?.outputText ?? "")}
                title="Copy result"
                type="button"
                variant="ghost"
              >
                Copy
              </Button>
              {run.learningEntry ? (
              <Button
                disabled={run.saved}
                className="h-7 min-h-7 px-2 text-xs"
                icon={<Save size={15} />}
                onClick={onSave}
                type="button"
                variant="primary"
              >
                {run.saved ? "Saved" : "Save"}
              </Button>
              ) : null}
            </div>
          </div>
        </>
      ) : null}
    </article>
  );
}

function LoadingRun({ title }: { title: string }) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-muted">
        <Loader2 className="animate-spin text-accent" size={16} />
        Running...
      </div>
    </div>
  );
}

function ErrorRun({ title, message }: { title: string; message: string }) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-danger">
        <AlertCircle size={16} />
        Action failed
      </div>
      <p className="mt-2 break-words text-sm leading-5 text-content">{message}</p>
    </div>
  );
}

function EntryTypeTags({
  disabled = false,
  entryType,
  onEntryTypeChange,
}: {
  disabled?: boolean;
  entryType: LearningEntryType;
  onEntryTypeChange: (entryType: LearningEntryType) => void;
}) {
  return (
    <div className="flex w-fit rounded-md border border-strong/10 bg-surface p-0.5">
      {(["word", "phrase", "pattern"] as LearningEntryType[]).map((type) => (
        <button
          className={`rounded px-1.5 py-0.5 text-[11px] font-medium transition ${
            entryType === type
              ? "bg-panel text-strong shadow-sm"
              : "text-muted hover:bg-panel hover:text-strong"
          } disabled:cursor-not-allowed disabled:opacity-60`}
          disabled={disabled}
          key={type}
          onClick={() => onEntryTypeChange(type)}
          type="button"
        >
          {entryTypeLabel(type)}
        </button>
      ))}
    </div>
  );
}

function newRunId() {
  return `run-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function isSingleWordTranslation(inputText: string, result: AiRunResult) {
  return Boolean(result.translation && singleWordText(inputText));
}

function wordLearningEntry(inputText: string, result: AiRunResult): LearningEntryInput {
  const translation = result.translation;
  if (!translation) {
    throw new Error("Translation result was empty.");
  }

  return {
    ...translation,
    word: translation.word.trim() || normalizedWordText(inputText),
    entry_type: "word",
    source_text: inputText,
    note: result.outputText,
  };
}

function singleWordText(text: string) {
  const word = normalizedWordText(text);
  return /^[A-Za-z]+(?:[-'][A-Za-z]+)*$/.test(word);
}

function normalizedWordText(text: string) {
  return text.trim().replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, "");
}

function markdownLabel(markdown: string, label: string) {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`(?:^|\\n)\\s*(?:[-*]\\s*)?(?:\\*\\*)?${escapedLabel}:(?:\\*\\*)?\\s*([^\\n]+)`, "i");
  return cleanInlineMarkdown(pattern.exec(markdown)?.[1] ?? "");
}

function cleanInlineMarkdown(value: string) {
  return value
    .replace(/^[-*: ]+/, "")
    .replace(/\*\*/g, "")
    .replace(/`/g, "")
    .trim();
}

function parsedEntryType(value: string, selectedText: string): LearningEntryType {
  const normalized = value.toLowerCase();
  if (normalized.includes("pattern")) return "pattern";
  if (normalized.includes("phrase")) return "phrase";
  if (normalized.includes("word")) return "word";
  return inferredEntryType(selectedText);
}

function inferredEntryType(selectedText: string): LearningEntryType {
  const text = selectedText.trim();
  if (/\.\.\.|_+|\{\{|}}/.test(text)) return "pattern";
  if (/[.!?]$/.test(text) || /\b(am|is|are|was|were|be|been|being|do|does|did|have|has|had|can|could|will|would|should|may|might|must)\b/i.test(text)) {
    return "pattern";
  }
  if (/\s/.test(text)) return "phrase";
  return "word";
}

function entryTypeLabel(type: LearningEntryType) {
  if (type === "pattern") return "Pattern";
  if (type === "phrase") return "Phrase";
  return "Word";
}

function featureAliasMatches(feature: AiFeature, featureId?: string) {
  if (!featureId) return false;
  const name = feature.name.toLowerCase();
  if (featureId === "translate") return feature.kind === "translation" || name.includes("translate");
  if (featureId === "rewrite") return feature.id.toLowerCase().includes("rewrite") || name.includes("rewrite");
  return false;
}
