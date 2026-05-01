import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { AlertCircle, BookPlus, ChevronLeft, ChevronRight, Clipboard, Loader2, Save, Volume2, Wand2, X } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AiFeature, AiRunResult, AppSettings, DisplayMode, LearningEntryInput, LearningEntryType, WordEntry } from "../../types";
import { analyzeLearningPoint, copyText, runAiFeature, speakText } from "../../lib/ai";
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
  capture?: CaptureActionState;
}

type CaptureActionState =
  | { status: "loading"; selectedText: string; contextText: string }
  | { status: "ready"; selectedText: string; contextText: string; result: AiRunResult; draft: LearningEntryInput; saved?: boolean }
  | { status: "error"; message: string; selectedText?: string; contextText?: string };

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
  const shellRef = useRef<HTMLElement>(null);
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
  }, [activeFeatureId, activePage.capture, activePage.inputText, activePage.state, isBar]);

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
    <main className="translation-window-shell h-screen bg-transparent" ref={shellRef}>
      <FloatingFrame
        autoHeight={!isBar}
        isPinned={isPinned}
        onCaptureSelection={activeFeature && activeFeature.kind !== "review" ? captureLearningPoint : undefined}
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
          autoHeight={!isBar}
          captureState={activePage.capture}
          inputText={activePage.inputText}
          pageState={activePage.state}
          onCancelCapture={cancelCaptureAction}
          onCaptureEntryTypeChange={updateCaptureEntryType}
          onInputChange={updateActiveInput}
          onSaveCapture={saveCaptureDraft}
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
          capture: "capture" in update ? update.capture : currentPage.capture,
        },
      };
      pagesRef.current = nextPages;
      return nextPages;
    });
  }

  async function captureLearningPoint() {
    if (!activeFeature || activeFeature.kind === "review") return;

    const selectedText = popupSelectedText();
    if (!selectedText) {
      setFeaturePage(activeFeature.id, {
        capture: { status: "error", message: "Select text inside the popup first." },
      });
      return;
    }

    await runCaptureAction(activeFeature, selectedText, captureContextText(activePage));
  }

  async function runCaptureAction(feature: AiFeature, selectedText: string, contextText: string) {
    setFeaturePage(feature.id, {
      capture: { status: "loading", selectedText, contextText },
    });

    try {
      const settings = await loadSettings();
      const result = await analyzeLearningPoint(selectedText, contextText, feature, settings);
      setFeaturePage(feature.id, {
        capture: {
          status: "ready",
          selectedText,
          contextText,
          result,
          draft: learningEntryDraft(selectedText, contextText, result.outputText),
        },
      });
    } catch (error) {
      setFeaturePage(feature.id, {
        capture: {
          status: "error",
          selectedText,
          contextText,
          message: errorMessage(error, "Capture learning point failed."),
        },
      });
    }
  }

  async function saveCaptureDraft() {
    if (!activeFeature) return;
    const capture = pagesRef.current[activeFeature.id]?.capture;
    if (!capture || capture.status !== "ready" || capture.saved) return;

    await addWord(capture.draft);
    await emit("englist://words-changed");
    setFeaturePage(activeFeature.id, {
      capture: { ...capture, saved: true },
    });
  }

  function cancelCaptureAction() {
    if (!activeFeature) return;
    setFeaturePage(activeFeature.id, { capture: undefined });
  }

  function updateCaptureEntryType(entryType: LearningEntryType) {
    if (!activeFeature) return;
    const capture = pagesRef.current[activeFeature.id]?.capture;
    if (!capture || capture.status !== "ready") return;
    setFeaturePage(activeFeature.id, {
      capture: {
        ...capture,
        saved: false,
        draft: { ...capture.draft, entry_type: entryType },
      },
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
  autoHeight?: boolean;
  captureState?: CaptureActionState;
  inputText: string;
  pageState: AiState;
  onCancelCapture: () => void;
  onCaptureEntryTypeChange: (entryType: LearningEntryType) => void;
  onInputChange: (value: string) => void;
  onSaveCapture: () => void | Promise<void>;
  onSubmit: (event: FormEvent) => void;
}

function FeatureTabPage({
  activeFeature,
  autoHeight = false,
  captureState,
  inputText,
  pageState,
  onCancelCapture,
  onCaptureEntryTypeChange,
  onInputChange,
  onSaveCapture,
  onSubmit,
}: FeatureTabPageProps) {
  if (activeFeature?.kind === "review") {
    return <ReviewFeaturePage feature={activeFeature} />;
  }

  return (
    <div className={`translation-tab-page flex min-h-0 flex-col gap-2 pt-2 ${autoHeight ? "flex-none" : "flex-1"}`}>
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
        className={`translation-content min-h-[220px] overflow-y-auto rounded-lg border border-strong/10 bg-surface/45 p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)] ${autoHeight ? "max-h-[720px] flex-none" : "flex-1"}`}
      >
        {pageState.status === "idle" ? <IdleState feature={activeFeature} /> : null}
        {pageState.status === "loading" && activeFeature ? <LoadingCard feature={activeFeature} /> : null}
        {pageState.status === "error" ? <ErrorCard feature={activeFeature} message={pageState.message} /> : null}
        {pageState.status === "ready" && activeFeature ? <AiResultPanel feature={activeFeature} result={pageState.result} /> : null}
        {captureState ? (
          <CaptureActionPanel
            capture={captureState}
            onCancel={onCancelCapture}
            onEntryTypeChange={onCaptureEntryTypeChange}
            onSave={onSaveCapture}
          />
        ) : null}
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
        className="translation-content min-h-[220px] flex-1 overflow-y-auto rounded-lg border border-strong/10 bg-surface/45 p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.035)]"
      >
        {currentWord ? (
          <div className="grid min-h-[138px] content-between gap-2.5">
            <div className="flex items-center justify-between gap-3 text-xs uppercase tracking-[0.14em] text-muted">
              <span>{entryTypeLabel(currentWord.entry_type)}</span>
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
                <span className="truncate">{entryTypeLabel(currentWord.entry_type)} / {currentWord.status}</span>
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
          <p className="text-sm text-muted">No learning entries to review.</p>
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

function CaptureActionPanel({
  capture,
  onCancel,
  onEntryTypeChange,
  onSave,
}: {
  capture: CaptureActionState;
  onCancel: () => void;
  onEntryTypeChange: (entryType: LearningEntryType) => void;
  onSave: () => void | Promise<void>;
}) {
  if (capture.status === "loading") {
    return (
      <div className="mt-3 rounded-lg border border-strong/10 bg-panel/80 p-2.5">
        <div className="flex items-center gap-2 text-sm text-muted">
          <Loader2 className="animate-spin text-accent" size={16} />
          Capturing learning point
        </div>
        <p className="mt-1 break-words text-xs text-muted">{capture.selectedText}</p>
      </div>
    );
  }

  if (capture.status === "error") {
    return (
      <div className="mt-3 rounded-lg border border-danger/40 bg-danger/10 p-2.5">
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2 text-sm text-danger">
            <AlertCircle size={16} />
            Capture failed
          </div>
          <Button
            aria-label="Dismiss capture error"
            className="h-7 min-h-7 w-7 px-0"
            icon={<X size={14} />}
            onClick={onCancel}
            variant="ghost"
          />
        </div>
        <p className="mt-1 break-words text-xs leading-5 text-content">{capture.message}</p>
      </div>
    );
  }

  return (
    <div className="mt-3 grid gap-2.5 rounded-lg border border-strong/10 bg-panel/85 p-2.5">
      <div className="flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2 text-sm font-medium text-strong">
          <BookPlus className="shrink-0 text-accent" size={16} />
          <span>Capture learning point</span>
        </div>
        <div className="flex shrink-0 gap-1">
          <Button
            aria-label="Cancel capture"
            className="h-7 min-h-7 w-7 px-0"
            icon={<X size={14} />}
            onClick={onCancel}
            title="Cancel"
            variant="ghost"
          />
        </div>
      </div>

      <div className="rounded-md border border-strong/10 bg-surface/60 p-2">
        <MarkdownRenderer content={capture.result.outputText} />
      </div>

      <div className="flex flex-col gap-2 border-t border-strong/10 pt-2 sm:flex-row sm:items-center sm:justify-between">
        <p className="min-w-0 truncate text-xs text-muted">
          Selected: {capture.selectedText}
        </p>
        <div className="flex shrink-0 items-center gap-2">
          <EntryTypeTags
            entryType={capture.draft.entry_type ?? "phrase"}
            onEntryTypeChange={onEntryTypeChange}
          />
          <Button
            disabled={capture.saved || !capture.selectedText.trim()}
            icon={<Save size={15} />}
            onClick={() => void onSave()}
            variant="primary"
          >
            {capture.saved ? "Saved" : "Save"}
          </Button>
        </div>
      </div>
    </div>
  );
}

function EntryTypeTags({
  entryType,
  onEntryTypeChange,
}: {
  entryType: LearningEntryType;
  onEntryTypeChange: (entryType: LearningEntryType) => void;
}) {
  return (
    <div className="flex rounded-md border border-strong/10 bg-surface p-0.5">
      {(["word", "phrase", "pattern"] as LearningEntryType[]).map((type) => (
        <button
          className={`rounded px-1.5 py-0.5 text-[11px] font-medium transition ${
            entryType === type
              ? "bg-panel text-strong shadow-sm"
              : "text-muted hover:bg-panel hover:text-strong"
          }`}
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

function emptyFeaturePage(): FeaturePageState {
  return {
    inputText: "",
    state: { status: "idle" },
  };
}

function popupSelectedText() {
  const selectedPageText = window.getSelection()?.toString().trim() ?? "";
  if (selectedPageText) return selectedPageText;

  const activeElement = document.activeElement;
  if (activeElement instanceof HTMLInputElement || activeElement instanceof HTMLTextAreaElement) {
    const start = activeElement.selectionStart ?? 0;
    const end = activeElement.selectionEnd ?? 0;
    return activeElement.value.slice(start, end).trim();
  }

  return "";
}

function captureContextText(page: FeaturePageState) {
  if (page.state.status === "ready") {
    return [page.inputText, page.state.result.outputText].filter(Boolean).join("\n\n");
  }

  return page.inputText;
}

function learningEntryDraft(selectedText: string, contextText: string, analysis: string): LearningEntryInput {
  const meaning = markdownLabel(analysis, "Meaning");
  const usage = markdownLabel(analysis, "Usage");
  const example = markdownLabel(analysis, "Example");
  const note = markdownLabel(analysis, "Note");

  return {
    word: selectedText,
    translation: meaning || "Learning point captured from popup selection",
    pos: markdownLabel(analysis, "Type") || inferredEntryType(selectedText),
    definition: [usage, note].filter(Boolean).join(" "),
    example,
    entry_type: parsedEntryType(markdownLabel(analysis, "Type"), selectedText),
    source_text: contextText,
    note: analysis,
  };
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
