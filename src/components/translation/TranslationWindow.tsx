import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AlertCircle, ChevronLeft, ChevronRight, Clipboard, Loader2, Volume2, Wand2 } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AiFeature, AiRunResult, AppSettings, DisplayMode, WordEntry } from "../../types";
import { copyText, runAiFeature, speakText } from "../../lib/ai";
import { applyAppearanceSettings } from "../../lib/appearance";
import { addWord, dueWords, listAiFeatures, listWords, loadSettings, savePopupPosition, savePopupSize } from "../../lib/database";
import { errorMessage } from "../../lib/errors";
import { Button } from "../ui/Button";
import { FloatingFrame, type PopupResizeStart } from "./FloatingFrame";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";

type AiState =
  | { status: "idle" }
  | { status: "loading"; text: string; mode: DisplayMode }
  | { status: "ready"; text: string; mode: DisplayMode; result: AiRunResult }
  | { status: "error"; message: string; mode: DisplayMode };

interface FeaturePageState {
  inputText: string;
  state: AiState;
}

interface RequestPayload {
  text: string;
  mode: DisplayMode;
  featureId?: string;
}

interface ErrorPayload {
  message: string;
  mode: DisplayMode;
  featureId?: string;
}

interface ReadyPayload {
  result: AiRunResult;
  feature: AiFeature;
  text: string;
  mode: DisplayMode;
}

export function TranslationWindow() {
  const [features, setFeatures] = useState<AiFeature[]>([]);
  const [activeFeatureId, setActiveFeatureId] = useState("");
  const [pages, setPages] = useState<Record<string, FeaturePageState>>({});
  const [isPinned, setIsPinned] = useState(true);
  const positionSaveTimerRef = useRef<number>();
  const sizeSaveTimerRef = useRef<number>();
  const featuresRef = useRef<AiFeature[]>([]);
  const activeFeatureIdRef = useRef("");
  const isPinnedRef = useRef(true);
  const pagesRef = useRef<Record<string, FeaturePageState>>({});
  const params = useMemo(() => new URLSearchParams(window.location.search), []);
  const windowName = params.get("window");
  const isBar = windowName === "float_bar";
  const enabledFeatures = useMemo(() => features.filter((feature) => feature.enabled), [features]);
  const activeFeature = enabledFeatures.find((feature) => feature.id === activeFeatureId) ?? enabledFeatures[0];
  const activePage = activeFeature
    ? pages[activeFeature.id] ?? emptyFeaturePage()
    : pages["missing-feature"] ?? emptyFeaturePage();

  useEffect(() => {
    featuresRef.current = features;
  }, [features]);

  useEffect(() => {
    activeFeatureIdRef.current = activeFeatureId;
  }, [activeFeatureId]);

  useEffect(() => {
    pagesRef.current = pages;
  }, [pages]);

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
        void runActiveFeature(event.payload.text, event.payload.mode, event.payload.featureId);
      }),
      listen<RequestPayload>("englist://ai-loading", (event) => {
        const feature = currentFeature(event.payload.featureId);
        if (feature) {
          setActiveFeatureId(feature.id);
          activeFeatureIdRef.current = feature.id;
          setFeaturePage(feature.id, {
            inputText: event.payload.text,
            state: {
              status: "loading",
              text: event.payload.text,
              mode: event.payload.mode,
            },
          });
        }
      }),
      listen<ErrorPayload>("englist://ai-error", (event) => {
        const feature = currentFeature(event.payload.featureId);
        if (feature) {
          setActiveFeatureId(feature.id);
          activeFeatureIdRef.current = feature.id;
          setFeaturePage(feature.id, {
            state: {
              status: "error",
              message: event.payload.message,
              mode: event.payload.mode,
            },
          });
        }
      }),
      listen<ReadyPayload>("englist://ai-ready", (event) => {
        setActiveFeatureId(event.payload.feature.id);
        activeFeatureIdRef.current = event.payload.feature.id;
        setFeaturePage(event.payload.feature.id, {
          inputText: event.payload.text,
          state: {
            status: "ready",
            text: event.payload.text,
            mode: event.payload.mode,
            result: event.payload.result,
          },
        });
      }),
      listen<AppSettings>("englist://settings-changed", (event) => {
        void applyAppearanceSettings(event.payload);
      }),
      listen("englist://features-changed", () => {
        void reloadFeatures();
      }),
    ];

    return () => {
      cleanups.forEach((cleanup) => {
        cleanup.then((unsubscribe) => unsubscribe());
      });
    };
  }, []);

  useEffect(() => {
    if (activeFeatureId || enabledFeatures.length === 0) return;
    setActiveFeatureId(enabledFeatures[0].id);
  }, [activeFeatureId, enabledFeatures]);

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
    if (isPinned || activePage.state.status === "idle" || activePage.state.mode !== "auto_bar" || activePage.state.status === "loading") return;
    const timeoutId = window.setTimeout(() => {
      getCurrentWindow().hide();
    }, 5000);
    return () => window.clearTimeout(timeoutId);
  }, [activePage.state, isPinned]);

  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") getCurrentWindow().hide();
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, []);

  async function initializePopup() {
    const [settings, nextFeatures] = await Promise.all([loadSettings(), listAiFeatures()]);
    await applyAppearanceSettings(settings);
    applyFeatureList(nextFeatures);
  }

  async function reloadFeatures() {
    applyFeatureList(await listAiFeatures());
  }

  function applyFeatureList(nextFeatures: AiFeature[]) {
    setFeatures(nextFeatures);
    featuresRef.current = nextFeatures;
    setPages((currentPages) => {
      const nextPages = nextFeatures.reduce<Record<string, FeaturePageState>>((accumulator, feature) => {
        accumulator[feature.id] = currentPages[feature.id] ?? emptyFeaturePage();
        return accumulator;
      }, {});
      pagesRef.current = nextPages;
      return nextPages;
    });
    const enabled = nextFeatures.filter((feature) => feature.enabled);
    const active = enabled.find((feature) => feature.id === activeFeatureIdRef.current) ?? enabled[0];
    if (active) {
      setActiveFeatureId(active.id);
      activeFeatureIdRef.current = active.id;
    }
  }

  function submitFeature(event: FormEvent) {
    event.preventDefault();
    if (!activeFeature) return;
    void runFeature(activePage.inputText, currentMode(), activeFeature);
  }

  async function runActiveFeature(rawText: string, mode: DisplayMode, featureId?: string) {
    const feature = await loadCurrentFeature(featureId);
    if (!feature) {
      setFeaturePage("missing-feature", {
        state: { status: "error", message: "No enabled AI features are available.", mode },
      });
      return;
    }

    await runFeature(rawText, mode, feature);
  }

  async function runFeature(rawText: string, mode: DisplayMode, feature: AiFeature) {
    const text = rawText.trim();
    if (!text) return;

    setActiveFeatureId(feature.id);
    setFeaturePage(feature.id, {
      inputText: text,
      state: { status: "loading", text, mode },
    });

    try {
      const settings = await loadSettings();
      await applyAppearanceSettings(settings);
      const result = await runAiFeature(text, feature, settings);
      setFeaturePage(feature.id, {
        inputText: text,
        state: { status: "ready", text, mode, result },
      });

      if (feature.kind === "translation" && feature.autoSaveToVocabulary && result.translation) {
        await addWord(result.translation);
        await emit("englist://words-changed");
      }
    } catch (error) {
      setFeaturePage(feature.id, {
        state: {
          status: "error",
          message: errorMessage(error, `${feature.name} failed.`),
          mode,
        },
      });
    }
  }

  async function loadCurrentFeature(featureId?: string) {
    const loadedFeatures = featuresRef.current.length > 0 ? featuresRef.current : await listAiFeatures();
    if (featuresRef.current.length === 0) {
      setFeatures(loadedFeatures);
      featuresRef.current = loadedFeatures;
    }

    const enabled = loadedFeatures.filter((feature) => feature.enabled);
    return (
      enabled.find((feature) => feature.id === featureId) ??
      enabled.find((feature) => feature.id === activeFeatureIdRef.current) ??
      enabled[0]
    );
  }

  function currentFeature(featureId?: string) {
    const enabled = featuresRef.current.filter((feature) => feature.enabled);
    return (
      enabled.find((feature) => feature.id === featureId) ??
      enabled.find((feature) => feature.id === activeFeatureIdRef.current) ??
      enabled[0]
    );
  }

  function currentMode(): DisplayMode {
    if (isBar) return "auto_bar";
    return "popup_card";
  }

  function updateActiveInput(value: string) {
    if (!activeFeature) return;
    setFeaturePage(activeFeature.id, { inputText: value });
  }

  return (
    <main className="translation-window-shell h-screen bg-transparent">
      <FloatingFrame
        isPinned={isPinned}
        onStartDrag={startWindowDrag}
        onStartResize={startWindowResize}
        onTogglePin={() => setIsPinned((currentIsPinned) => !currentIsPinned)}
      >
        <FeatureTabs
          activeFeatureId={activeFeature?.id ?? ""}
          features={enabledFeatures}
          onFeatureChange={setActiveFeatureId}
        />
        <FeatureTabPage
          activeFeature={activeFeature}
          inputText={activePage.inputText}
          pageState={activePage.state}
          onInputChange={updateActiveInput}
          onSubmit={submitFeature}
        />
      </FloatingFrame>
    </main>
  );

  function setFeaturePage(featureId: string, update: Partial<FeaturePageState>) {
    setPages((currentPages) => {
      const currentPage = currentPages[featureId] ?? emptyFeaturePage();
      const nextPages = {
        ...currentPages,
        [featureId]: {
          inputText: update.inputText ?? currentPage.inputText,
          state: update.state ?? currentPage.state,
        },
      };
      pagesRef.current = nextPages;
      return nextPages;
    });
  }
}

async function startWindowDrag() {
  await getCurrentWindow().startDragging();
}

async function startWindowResize({ direction }: PopupResizeStart) {
  await invoke("start_popup_resize", { direction }).catch((error) => {
    console.warn("Failed to start popup resize", error);
  });
}

interface FeatureTabsProps {
  features: AiFeature[];
  activeFeatureId: string;
  onFeatureChange: (featureId: string) => void;
}

function FeatureTabs({ activeFeatureId, features, onFeatureChange }: FeatureTabsProps) {
  if (features.length <= 1) return null;

  return (
    <div className="min-h-9 w-full shrink-0 overflow-x-auto rounded-lg border border-strong/10 bg-surface/70 p-0.5">
      <div className="flex min-w-full gap-1">
        {features.map((feature) => (
          <button
            className={`h-8 shrink-0 rounded-md px-2.5 text-xs font-medium transition ${
              feature.id === activeFeatureId ? "bg-panel text-strong shadow-sm" : "text-muted hover:bg-panel hover:text-strong"
            }`}
            key={feature.id}
            onClick={() => onFeatureChange(feature.id)}
            type="button"
          >
            {feature.name}
          </button>
        ))}
      </div>
    </div>
  );
}

interface FeatureTabPageProps {
  activeFeature?: AiFeature;
  inputText: string;
  pageState: AiState;
  onInputChange: (value: string) => void;
  onSubmit: (event: FormEvent) => void;
}

function FeatureTabPage({
  activeFeature,
  inputText,
  pageState,
  onInputChange,
  onSubmit,
}: FeatureTabPageProps) {
  if (activeFeature?.kind === "review") {
    return <ReviewFeaturePage feature={activeFeature} />;
  }

  return (
    <div className="translation-tab-page flex min-h-0 flex-1 flex-col gap-2 pt-2">
      <section className="translation-action-area shrink-0">
        <AiForm
          activeFeature={activeFeature}
          inputText={inputText}
          isSubmitting={pageState.status === "loading"}
          onInputChange={onInputChange}
          onSubmit={onSubmit}
        />
      </section>
      <section
        className="translation-content min-h-0 flex-1 overflow-y-auto rounded-lg border border-strong/10 bg-surface/45 p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)]"
      >
        {pageState.status === "idle" ? <IdleState feature={activeFeature} /> : null}
        {pageState.status === "loading" && activeFeature ? <LoadingCard feature={activeFeature} /> : null}
        {pageState.status === "error" ? <ErrorCard feature={activeFeature} message={pageState.message} /> : null}
        {pageState.status === "ready" && activeFeature ? <AiResultPanel feature={activeFeature} result={pageState.result} /> : null}
      </section>
    </div>
  );
}

function ReviewFeaturePage({
  feature,
}: {
  feature: AiFeature;
}) {
  const [words, setWords] = useState<WordEntry[]>([]);
  const [index, setIndex] = useState(0);
  const [speechError, setSpeechError] = useState("");
  const displayWords = useMemo(() => {
    const due = dueWords(words);
    return due.length > 0 ? due : words.filter((word) => word.status !== "mastered");
  }, [words]);
  const currentWord = displayWords[index % Math.max(1, displayWords.length)];

  useEffect(() => {
    void refreshWords();
    const cleanupPromise = listen("englist://words-changed", () => {
      void refreshWords();
    });
    return () => {
      cleanupPromise.then((cleanup) => cleanup());
    };
  }, []);

  useEffect(() => {
    if (displayWords.length <= 1) return;
    const intervalId = window.setInterval(() => {
      setIndex((currentIndex) => (currentIndex + 1) % displayWords.length);
    }, feature.reviewIntervalSeconds * 1000);
    return () => window.clearInterval(intervalId);
  }, [displayWords.length, feature.reviewIntervalSeconds]);

  useEffect(() => {
    if (index < displayWords.length) return;
    setIndex(0);
  }, [displayWords.length, index]);

  async function refreshWords() {
    setWords(await listWords());
  }

  function showPreviousWord() {
    if (displayWords.length === 0) return;
    setIndex((currentIndex) => (currentIndex - 1 + displayWords.length) % displayWords.length);
  }

  function showNextWord() {
    if (displayWords.length === 0) return;
    setIndex((currentIndex) => (currentIndex + 1) % displayWords.length);
  }

  async function speakCurrentWord() {
    if (!currentWord) return;
    setSpeechError("");
    try {
      await speakText(currentWord.word);
    } catch (error) {
      setSpeechError(errorMessage(error, "Speech failed."));
    }
  }

  return (
    <div className="translation-tab-page flex min-h-0 flex-1 flex-col gap-2 pt-2">
      <section
        className="translation-content min-h-0 flex-1 overflow-y-auto rounded-lg border border-strong/10 bg-surface/45 p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)]"
      >
        {currentWord ? (
          <div className="grid min-h-[138px] content-between gap-2.5">
            <div className="flex items-center justify-between gap-3 text-xs uppercase tracking-[0.14em] text-muted">
              <span>Vocabulary</span>
              <span>{index + 1}/{displayWords.length}</span>
            </div>
            <div className="grid gap-1.5">
              <h2 className="break-words text-xl font-semibold leading-tight text-strong">{currentWord.word}</h2>
              <p className="break-words text-base font-medium text-accent">{currentWord.translation}</p>
              {currentWord.definition ? (
                <p className="break-words text-sm leading-5 text-content">{currentWord.definition}</p>
              ) : null}
              {currentWord.example ? (
                <p className="rounded-md border border-strong/10 bg-example p-2 text-xs leading-5 text-muted">
                  {currentWord.example}
                </p>
              ) : null}
            </div>
            <div className="flex items-center justify-between gap-2 text-xs text-muted">
              <Button
                aria-label="Previous vocabulary"
                className="h-7 min-h-7 w-7 rounded-md px-0"
                disabled={displayWords.length <= 1}
                icon={<ChevronLeft size={15} />}
                onClick={showPreviousWord}
              />
              <div className="flex min-w-0 flex-1 items-center justify-between gap-2">
                <span className="truncate">{currentWord.status}</span>
                <span className="shrink-0">{feature.reviewIntervalSeconds}s interval</span>
              </div>
              {feature.speechEnabled ? (
                <Button
                  aria-label="Speak vocabulary"
                  className="h-7 min-h-7 w-7 rounded-md px-0"
                  icon={<Volume2 size={14} />}
                  onClick={speakCurrentWord}
                  title="Speak vocabulary"
                />
              ) : null}
              <Button
                aria-label="Next vocabulary"
                className="h-7 min-h-7 w-7 rounded-md px-0"
                disabled={displayWords.length <= 1}
                icon={<ChevronRight size={15} />}
                onClick={showNextWord}
              />
            </div>
            {speechError ? <p className="text-xs text-danger">{speechError}</p> : null}
          </div>
        ) : (
          <p className="text-sm text-muted">No vocabulary entries to review.</p>
        )}
      </section>
    </div>
  );
}

interface AiFormProps {
  activeFeature?: AiFeature;
  inputText: string;
  isSubmitting: boolean;
  onInputChange: (value: string) => void;
  onSubmit: (event: FormEvent) => void;
}

function AiForm({ activeFeature, inputText, isSubmitting, onInputChange, onSubmit }: AiFormProps) {
  const [speechError, setSpeechError] = useState("");
  const canSpeak = Boolean(activeFeature?.speechEnabled);

  async function speakInputText() {
    setSpeechError("");
    try {
      await speakText(inputText);
    } catch (error) {
      setSpeechError(errorMessage(error, "Speech failed."));
    }
  }

  return (
    <div className="grid gap-1.5">
      <form className="translation-form flex w-full gap-1.5 rounded-lg border border-strong/10 bg-input p-1 shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]" onSubmit={onSubmit}>
        <input
          className="h-8 min-w-0 flex-1 rounded-md border-0 bg-transparent px-2 text-sm text-strong outline-none placeholder:text-muted"
          onChange={(event) => onInputChange(event.target.value)}
          placeholder="Enter text"
          value={inputText}
        />
        <Button
          aria-label="Run feature"
          className="h-8 min-h-8 w-8 shrink-0 rounded-md px-0"
          disabled={isSubmitting || !inputText.trim() || !activeFeature}
          icon={isSubmitting ? <Loader2 className="animate-spin" size={16} /> : <Wand2 size={16} />}
          title="Run feature"
          type="submit"
          variant="primary"
        />
        {canSpeak ? (
          <Button
            aria-label="Speak input text"
            className="h-8 min-h-8 w-8 shrink-0 rounded-md px-0"
            disabled={!inputText.trim()}
            icon={<Volume2 size={16} />}
            onClick={speakInputText}
            title="Speak input text"
            type="button"
          />
        ) : null}
      </form>
      {speechError ? <p className="text-xs text-danger">{speechError}</p> : null}
    </div>
  );
}

function IdleState({ feature }: { feature?: AiFeature }) {
  return (
    <p className="text-sm text-muted">
      {feature ? `${feature.name} is ready. Select text with the shortcut, or type above.` : "No enabled AI feature."}
    </p>
  );
}

function LoadingCard({ feature }: { feature: AiFeature }) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-muted">
        <Loader2 className="animate-spin text-accent" size={16} />
        Running {feature.name}
      </div>
      <p className="mt-2 text-sm text-muted">Waiting for the AI result...</p>
    </div>
  );
}

function ErrorCard({ feature, message }: { feature?: AiFeature; message: string }) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-danger">
        <AlertCircle size={16} />
        {feature ? `${feature.name} failed` : "AI feature failed"}
      </div>
      <p className="mt-2 break-words text-sm leading-5 text-content">{message}</p>
    </div>
  );
}

function AiResultPanel({ feature, result }: { feature: AiFeature; result: AiRunResult }) {
  return (
    <div className="grid min-w-0 gap-2">
      <MarkdownRenderer content={result.outputText} />
      {feature.kind !== "translation" ? <div className="flex justify-end border-t border-strong/10 pt-3">
        <Button onClick={() => copyText(result.outputText)} icon={<Clipboard size={16} />}>
          Copy
        </Button>
      </div> : null}
    </div>
  );
}

function emptyFeaturePage(): FeaturePageState {
  return {
    inputText: "",
    state: { status: "idle" },
  };
}
