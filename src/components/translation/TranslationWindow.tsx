import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AlertCircle, Copy, Loader2, Trash2, X } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AiFeature, AiFeatureIcon, AiRunResult, AppSettings, LearningEntryInput, LearningEntryType, Panel, ToolbarTool, WordEntry } from "../../types";
import { copyText, runAiFeatureStream } from "../../lib/ai";
import { applyAppearanceSettings } from "../../lib/appearance";
import { addWord, listAiFeatures, listPanels, listWords, loadSettings, loadToolbarTools, savePopupPosition, savePopupSize, saveSettings } from "../../lib/database";
import { DEFAULT_PANELS } from "../../lib/defaults";
import { errorMessage } from "../../lib/errors";
import { FeatureIcon } from "../../lib/featureIcons";
import { syncNativeToolbar } from "../../lib/nativeToolbar";
import { FloatingFrame, type PopupResizeStart } from "./FloatingFrame";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";
import { registerPanel, getPanelComponent } from "../../lib/panelRegistry";
import { ReviewPanel } from "./ReviewPanel";
import { NotesPanel } from "./NotesPanel";

registerPanel("review", ReviewPanel);
registerPanel("notes", NotesPanel);

type WorkspaceRunStatus = "loading" | "streaming" | "ready" | "error";
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
  streamingText?: string;
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
  const [isPinned, setIsPinned] = useState(false);
  const [panels, setPanels] = useState<Panel[]>(DEFAULT_PANELS);
  const [activePanelId, setActivePanelId] = useState<string>("translate");
  const [words, setWords] = useState<WordEntry[]>([]);
  const positionSaveTimerRef = useRef<number>();
  const sizeSaveTimerRef = useRef<number>();
  const shellRef = useRef<HTMLElement>(null);
  const featuresRef = useRef<AiFeature[]>([]);
  const toolsRef = useRef<ToolbarTool[]>([]);
  const inputTextRef = useRef("");
  const runsRef = useRef<WorkspaceRun[]>([]);
  const isPinnedRef = useRef(false);
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
    toolsRef.current = tools;
  }, [tools]);

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
      listen<RequestPayload>("lexi://ai-request", (event) => {
        if (isBar) return;
        void runActiveFeature(event.payload.text, event.payload.featureId);
      }),
      listen<RequestPayload>("lexi://ai-loading", (event) => {
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
      listen<ErrorPayload>("lexi://ai-error", (event) => {
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
      listen<ReadyPayload>("lexi://ai-ready", (event) => {
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
      listen<AppSettings>("lexi://settings-changed", (event) => {
        void applyAppearanceSettings(event.payload);
        void syncNativeToolbarActions(featuresRef.current);
      }),
      listen("lexi://features-changed", () => {
        void reloadFeatures();
      }),
      listen("lexi://tools-changed", () => {
        void loadToolbarTools().then((t) => setTools(t));
      }),
      listen("lexi://popup-shown", () => {
        resetPopupWorkspace();
        // Ensure the popup enters Tauri's focused state so that
        // onFocusChanged(false) fires when clicking outside.
        // Delay allows text reading (double-ctrl path) to finish first.
        if (!isBar) {
          window.setTimeout(() => {
            getCurrentWindow().setFocus().catch(() => {});
          }, 200);
        }
      }),
      listen("lexi://words-changed", async () => {
        const refreshed = await listWords();
        setWords(refreshed);
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
      latestRun.status === "loading" ||
      latestRun.status === "streaming"
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

      await runAiFeatureStream(text, feature, settings, {
        onChunk: (accumulated) => {
          updateWorkspaceRun(runId, { status: "streaming", streamingText: accumulated });
        },
        onDone: (result) => {
          let saved = false;
          if (feature.kind === "translation" && feature.autoSaveToVocabulary && isSingleWordInput(text)) {
            void addWord(wordLearningEntry(text, result));
            void emit("lexi://words-changed");
            saved = true;
          }
          const learningEntry = feature.id === "extract" ? learningEntryDraft(text, result.outputText) : undefined;
          updateWorkspaceRun(runId, { status: "ready", result, streamingText: undefined, saved, learningEntry });
        },
        onError: (message) => {
          updateWorkspaceRun(runId, { status: "error", message });
        },
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
    await invoke("execute_tool", { id: toolId, text });
  }

  async function saveLearningEntry(runId: string) {
    const run = runsRef.current.find((item) => item.id === runId);
    if (!run?.learningEntry || run.saved) return;

    await addWord(run.learningEntry);
    await emit("lexi://words-changed");
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
        className={isBar ? undefined : "translation-frame-popup"}
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
  const targetHeight = clamp(Math.ceil(pageTop + pageHeight + contentOverflow + 18), 420, 900);
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
  onDismissRun: (id: string) => void;
  onSelectRun: (id: string) => void;
}) {
  return (
    <div className="flex items-center gap-0.5 border-b border-strong/10 px-2 pt-1">
      <div className="flex min-w-0 flex-1 gap-0.5 overflow-x-auto">
        {runs.map((run) => (
          <button
            className={`group flex shrink-0 items-center gap-1 px-2 py-[3px] text-[11px] transition ${
              run.id === activeRunId
                ? "text-strong border-b-[1.5px] border-strong/25"
                : "text-muted hover:text-strong"
            }`}
            key={run.id}
            onClick={() => onSelectRun(run.id)}
            title={`${run.title}: ${run.inputText}`}
            type="button"
          >
            <span className={run.status === "loading" ? "opacity-50" : ""}>
              <FeatureIcon icon={run.icon ?? "wand"} size={10} />
            </span>
            <span className="max-w-[80px] truncate">{run.title}</span>
            <span
              aria-label="Close result"
              className="grid h-3 w-3 shrink-0 place-items-center rounded text-muted hover:text-strong"
              onClick={(event) => { event.preventDefault(); event.stopPropagation(); onDismissRun(run.id); }}
              role="button"
              tabIndex={0}
              title="Close result"
            >
              <X size={9} />
            </span>
          </button>
        ))}
      </div>
      <button
        aria-label="Close all results"
        className="grid h-5 w-5 shrink-0 place-items-center rounded text-muted hover:bg-surfaceHover hover:text-strong transition-colors"
        onClick={onClearRuns}
        title="Close all results"
        type="button"
      >
        <Trash2 size={11} />
      </button>
    </div>
  );
}

function AiForm({
  inputText,
  panelItems,
  runs,
  onInputChange,
  onRunFeatureInput,
  onToolAction,
  onSubmit,
}: {
  inputText: string;
  panelItems: Array<{ kind: "feature"; feature: AiFeature } | { kind: "tool"; tool: ToolbarTool }>;
  runs: WorkspaceRun[];
  onInputChange: (value: string) => void;
  onRunFeatureInput: (feature: AiFeature) => void;
  onToolAction: (toolId: string) => void;
  onSubmit: (event: FormEvent) => void;
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const [isMultiline, setIsMultiline] = useState(false);

  // Button group width: each button 30px + 2px gap between, plus 4px gap before group
  const buttonGroupWidth = panelItems.length > 0
    ? panelItems.length * 30 + (panelItems.length - 1) * 2 + 4
    : 0;

  function resizeTextarea(element: HTMLTextAreaElement) {
    const prevHeight = element.style.height;

    // Measure at row-layout width (full width minus buttons) — this value is
    // the same regardless of current layout, so no oscillation when switching.
    const container = element.parentElement!;
    const cs = getComputedStyle(container);
    const contentWidth = container.clientWidth
      - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
    const rowWidth = Math.max(50, contentWidth - buttonGroupWidth);

    element.style.flex = "none";
    element.style.width = `${rowWidth}px`;
    element.style.height = "auto";
    void element.offsetHeight;
    const rowScrollHeight = element.scrollHeight;

    // Restore to current layout width
    element.style.flex = "";
    element.style.width = "";

    // Set height at current layout width with smooth transition
    element.style.height = "auto";
    const newHeight = Math.min(140, element.scrollHeight);
    element.style.height = prevHeight || `${newHeight}px`;
    void element.offsetHeight;
    element.style.height = `${newHeight}px`;

    setIsMultiline(rowScrollHeight > 30);
  }

  useEffect(() => {
    if (textareaRef.current) resizeTextarea(textareaRef.current);
  }, [inputText]);

  // Re-measure when container resizes (window drag, panel resize)
  useEffect(() => {
    const container = textareaRef.current?.parentElement;
    if (!container) return;
    const observer = new ResizeObserver(() => {
      if (textareaRef.current) resizeTextarea(textareaRef.current);
    });
    observer.observe(container);
    return () => observer.disconnect();
  }, [buttonGroupWidth]);

  return (
    <form className="px-2 pt-1" onSubmit={onSubmit}>
      <div className={`flex gap-x-1 gap-y-1 rounded-lg border border-strong/10 bg-input p-1 ${isMultiline ? "flex-col" : "items-center"}`}>
        <textarea
          className={`max-h-[140px] min-h-[24px] min-w-0 resize-none border-0 bg-transparent px-1.5 py-1 text-sm leading-[1.3] text-strong outline-none placeholder:text-muted transition-[height] duration-150 ease-out ${isMultiline ? "" : "flex-1"}`}
          onChange={(event) => { onInputChange(event.target.value); resizeTextarea(event.currentTarget); }}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              (event.target as HTMLTextAreaElement).form?.requestSubmit();
            }
          }}
          onInput={(event) => resizeTextarea(event.currentTarget as HTMLTextAreaElement)}
          placeholder="Enter text"
          ref={textareaRef}
          rows={1}
          value={inputText}
        />
        {panelItems.length > 0 ? (
          <div className="flex shrink-0 gap-0.5">
            {panelItems.map((item) => (
              <AiFormActionButton key={item.kind === "feature" ? item.feature.id : item.tool.id} item={item} runs={runs} inputText={inputText} onRunFeatureInput={onRunFeatureInput} onToolAction={onToolAction} />
            ))}
          </div>
        ) : null}
      </div>
    </form>
  );
}

function AiFormActionButton({
  item,
  runs,
  inputText,
  onRunFeatureInput,
  onToolAction,
}: {
  item: { kind: "feature"; feature: AiFeature } | { kind: "tool"; tool: ToolbarTool };
  runs: WorkspaceRun[];
  inputText: string;
  onRunFeatureInput: (feature: AiFeature) => void;
  onToolAction: (toolId: string) => void;
}) {
  if (item.kind === "tool") {
    return (
      <button
        aria-label={`${item.tool.name} input text`}
        className="grid h-[30px] w-[30px] shrink-0 place-items-center rounded-md border border-border bg-surface text-content hover:bg-surfaceHover hover:text-strong disabled:opacity-40"
        disabled={!inputText.trim()}
        onClick={() => onToolAction(item.tool.id)}
        title={`${item.tool.name} input text`}
        type="button"
      >
        <FeatureIcon icon={item.tool.icon} size={14} />
      </button>
    );
  }
  const isLoading = runs.some((run) => (run.status === "loading" || run.status === "streaming") && run.featureId === item.feature.id && run.kind === "feature");
  return (
    <button
      aria-label={`${item.feature.name} input text`}
      className="grid h-[30px] w-[30px] shrink-0 place-items-center rounded-md border border-border bg-surface text-content hover:bg-surfaceHover hover:text-strong disabled:opacity-40"
      disabled={isLoading || !inputText.trim()}
      onClick={() => onRunFeatureInput(item.feature)}
      title={`${item.feature.name} input text`}
      type="button"
    >
      <FeatureIcon icon={item.feature.icon} size={14} />
    </button>
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
  onEntryTypeChange: (type: LearningEntryType) => void;
  onSave: () => void;
}) {
  return (
    <article className="grid min-w-0 gap-1.5 px-3 py-2">
      {run.status === "loading" ? <LoadingRun title={run.title} /> : null}
      {run.status === "streaming" && run.streamingText != null ? (
        <div className="leading-[1.65] tracking-[-0.01em] text-content">
          <MarkdownRenderer content={run.streamingText} />
        </div>
      ) : null}
      {run.status === "error" ? <ErrorRun title={run.title} message={run.message ?? "Action failed."} /> : null}
      {run.status === "ready" && run.result ? (
        <>
          <div className="leading-[1.65] tracking-[-0.01em] text-content">
            <MarkdownRenderer content={run.result.outputText} />
          </div>
          <div className="flex items-center justify-center gap-2">
            {run.learningEntry ? (
              <EntryTypeTags disabled={run.saved} entryType={run.learningEntry.entry_type ?? "phrase"} onEntryTypeChange={onEntryTypeChange} />
            ) : null}
            <button
              aria-label="Copy result"
              className="grid h-5 w-5 place-items-center rounded text-muted hover:bg-surfaceHover hover:text-strong transition-colors"
              onClick={() => copyText(run.result?.outputText ?? "")}
              title="Copy result"
              type="button"
            >
              <Copy size={12} />
            </button>
            {run.learningEntry ? (
              <button
                disabled={run.saved}
                className="rounded-md px-3 py-1 text-[11px] font-medium text-white bg-accent hover:bg-accentHover disabled:opacity-40 transition-colors"
                onClick={onSave}
                type="button"
              >
                {run.saved ? "Saved" : "Save"}
              </button>
            ) : null}
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
  onEntryTypeChange: (type: LearningEntryType) => void;
}) {
  return (
    <div className="flex rounded-md border border-strong/10 p-0.5">
      {(["word", "phrase", "pattern"] as LearningEntryType[]).map((type) => (
        <button
          className={`rounded-[5px] px-2 py-0.5 text-[10px] font-medium transition ${
            entryType === type
              ? "bg-strong/10 text-strong"
              : "text-muted hover:text-strong"
          } disabled:cursor-not-allowed disabled:opacity-40`}
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

function learningEntryDraft(selectedText: string, analysis: string): LearningEntryInput {
  const meaning = markdownLabel(analysis, "Meaning");
  const usage = markdownLabel(analysis, "Usage");
  const example = markdownLabel(analysis, "Example");
  const note = markdownLabel(analysis, "Note");

  return {
    word: selectedText,
    translation: meaning || "Learning point extracted from selected text",
    pos: markdownLabel(analysis, "Type") || inferredEntryType(selectedText),
    definition: [usage, note].filter(Boolean).join(" "),
    example,
    entry_type: parsedEntryType(markdownLabel(analysis, "Type"), selectedText),
    source_text: selectedText,
    note: analysis,
  };
}

function isSingleWordInput(inputText: string) {
  return Boolean(normalizedWordText(inputText) && singleWordText(inputText));
}

function wordLearningEntry(inputText: string, result: AiRunResult): LearningEntryInput {
  const translation = result.translation;
  const word = normalizedWordText(inputText);

  return {
    word,
    translation: translation?.translation.trim() || translationSummary(result.outputText),
    pos: translation?.pos.trim() || "",
    definition: translation?.definition.trim() || "",
    example: translation?.example.trim() || "",
    entry_type: "word",
    source_text: inputText,
    note: result.outputText,
  };
}

function translationSummary(outputText: string) {
  return firstContentLine(outputText) || outputText.trim() || "Translation saved from AI output";
}

function firstContentLine(text: string) {
  return text
    .split(/\r?\n/)
    .map((line) => line.replace(/^#{1,6}\s+/, "").replace(/^[-*]\s+/, "").trim())
    .find(Boolean) ?? "";
}

function singleWordText(text: string) {
  const word = normalizedWordText(text);
  return /^[A-Za-z]+(?:[-'][A-Za-z]+)*$/.test(word);
}

function normalizedWordText(text: string) {
  return text.trim().replace(/^[^A-Za-z]+|[^A-Za-z]+$/g, "").toLowerCase();
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
