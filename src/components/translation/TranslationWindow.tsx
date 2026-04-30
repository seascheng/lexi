import { listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { AlertCircle, Loader2, Wand2 } from "lucide-react";
import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AppSettings, DisplayMode, TranslationResult } from "../../types";
import { applyAppearanceSettings } from "../../lib/appearance";
import { addWord, loadSettings, savePopupPosition } from "../../lib/database";
import { errorMessage } from "../../lib/errors";
import { translateText } from "../../lib/translation";
import { Button } from "../ui/Button";
import { FloatingFrame } from "./FloatingFrame";
import { TranslationResultPanel } from "./TranslationResultPanel";

type TranslationState =
  | { status: "idle" }
  | { status: "loading"; text: string; mode: DisplayMode }
  | { status: "ready"; result: TranslationResult; mode: DisplayMode }
  | { status: "error"; message: string; mode: DisplayMode };

interface LoadingPayload {
  text: string;
  mode: DisplayMode;
}

interface RequestPayload {
  text: string;
  mode: DisplayMode;
}

interface ReadyPayload {
  result: TranslationResult;
  mode: DisplayMode;
}

interface ErrorPayload {
  message: string;
  mode: DisplayMode;
}

export function TranslationWindow() {
  const [state, setState] = useState<TranslationState>({ status: "idle" });
  const [inputText, setInputText] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const layoutRef = useRef<HTMLDivElement>(null);
  const resizeFrameRef = useRef<number>();
  const positionSaveTimerRef = useRef<number>();
  const params = useMemo(() => new URLSearchParams(window.location.search), []);
  const windowName = params.get("window");
  const isBar = windowName === "float_bar";

  useEffect(() => {
    void loadSettings()
      .then((settings) => applyAppearanceSettings(settings))
      .catch((error) => {
        console.error("Failed to apply appearance settings", error);
      });

    const cleanups = [
      listen<RequestPayload>("englist://translation-request", (event) => {
        setInputText(event.payload.text);
        void runTranslation(event.payload.text, event.payload.mode);
      }),
      listen<LoadingPayload>("englist://translation-loading", (event) => {
        setInputText(event.payload.text);
        setState({ status: "loading", ...event.payload });
      }),
      listen<ReadyPayload>("englist://translation-ready", (event) => {
        setInputText(event.payload.result.word);
        setState({ status: "ready", ...event.payload });
      }),
      listen<ErrorPayload>("englist://translation-error", (event) => {
        setState({ status: "error", ...event.payload });
      }),
      listen<AppSettings>("englist://settings-changed", (event) => {
        void applyAppearanceSettings(event.payload);
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
    const frameId = window.requestAnimationFrame(() => {
      void fitPopupToContent(layoutRef.current);
    });
    return () => window.cancelAnimationFrame(frameId);
  }, [inputText, isBar, state]);

  useEffect(() => {
    if (isBar || !layoutRef.current) return;

    const observer = new ResizeObserver(() => {
      if (resizeFrameRef.current) {
        window.cancelAnimationFrame(resizeFrameRef.current);
      }

      resizeFrameRef.current = window.requestAnimationFrame(() => {
        void fitPopupToContent(layoutRef.current);
      });
    });

    observer.observe(layoutRef.current);
    return () => {
      observer.disconnect();
      if (resizeFrameRef.current) {
        window.cancelAnimationFrame(resizeFrameRef.current);
      }
    };
  }, [isBar]);

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
    if (state.status === "idle" || state.mode !== "auto_bar" || state.status === "loading") return;
    const timeoutId = window.setTimeout(() => {
      getCurrentWindow().hide();
    }, 5000);
    return () => window.clearTimeout(timeoutId);
  }, [state]);

  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") getCurrentWindow().hide();
    }
    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, []);

  function submitTranslation(event: FormEvent) {
    event.preventDefault();
    void runTranslation(inputText, currentMode());
  }

  async function runTranslation(rawText: string, mode: DisplayMode) {
    const text = rawText.trim();
    if (!text) return;

    setIsSubmitting(true);
    setInputText(text);
    setState({ status: "loading", text, mode });

    try {
      const settings = await loadSettings();
      await applyAppearanceSettings(settings);
      const result = await translateText(text, settings);
      setState({ status: "ready", result, mode });

      if (settings.autoSave) {
        await addWord(result);
      }
    } catch (error) {
      setState({ status: "error", message: errorMessage(error, "Translation failed."), mode });
    } finally {
      setIsSubmitting(false);
    }
  }

  function currentMode(): DisplayMode {
    if (isBar) return "auto_bar";
    return "popup_card";
  }

  return (
    <main className="translation-window-shell h-screen bg-transparent">
      <FloatingFrame contentRef={layoutRef} onClose={() => getCurrentWindow().hide()} onStartDrag={startWindowDrag}>
        <section className="translation-action-area">
          <TranslationForm
            inputText={inputText}
            isSubmitting={isSubmitting || state.status === "loading"}
            onInputChange={setInputText}
            onSubmit={submitTranslation}
          />
        </section>
        <section className="translation-content mt-3 min-h-0 overflow-visible">
          {state.status === "idle" ? <IdleState /> : null}
          {state.status === "loading" ? <LoadingCard /> : null}
          {state.status === "error" ? <ErrorCard message={state.message} /> : null}
          {state.status === "ready" ? <TranslationResultPanel compact result={state.result} /> : null}
        </section>
      </FloatingFrame>
    </main>
  );
}

async function startWindowDrag() {
  await getCurrentWindow().startDragging();
}

async function fitPopupToContent(layoutElement: HTMLDivElement | null) {
  if (!layoutElement) return;

  const width = Math.max(360, window.innerWidth);
  const naturalHeight = layoutElement.scrollHeight + 24;
  const nextHeight = Math.ceil(Math.max(150, naturalHeight));
  if (Math.abs(window.innerHeight - nextHeight) < 2) return;

  try {
    await getCurrentWindow().setSize(new LogicalSize(width, nextHeight));
  } catch (error) {
    console.warn("Failed to fit popup to content", error);
  }
}

interface TranslationFormProps {
  inputText: string;
  isSubmitting: boolean;
  onInputChange: (value: string) => void;
  onSubmit: (event: FormEvent) => void;
}

function TranslationForm({ inputText, isSubmitting, onInputChange, onSubmit }: TranslationFormProps) {
  return (
    <form className="translation-form flex gap-2 rounded-xl border border-strong/10 bg-input p-1.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.04)]" onSubmit={onSubmit}>
      <input
        className="h-9 min-w-0 flex-1 rounded-lg border-0 bg-transparent px-2.5 text-sm text-strong outline-none placeholder:text-muted"
        onChange={(event) => onInputChange(event.target.value)}
        placeholder="Enter a word or phrase"
        value={inputText}
      />
      <Button
        className="h-9 min-h-9 shrink-0 rounded-lg px-3"
        disabled={isSubmitting || !inputText.trim()}
        icon={isSubmitting ? <Loader2 className="animate-spin" size={16} /> : <Wand2 size={16} />}
        type="submit"
        variant="primary"
      >
        Translate
      </Button>
    </form>
  );
}

function IdleState() {
  return <p className="text-sm text-muted">Select text with the shortcut, or type above to translate.</p>;
}

function LoadingCard() {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-muted">
        <Loader2 className="animate-spin text-accent" size={16} />
        Translating
      </div>
      <p className="mt-3 text-sm text-muted">Waiting for the translation result...</p>
    </div>
  );
}

function ErrorCard({ message }: { message: string }) {
  return (
    <div className="min-w-0">
      <div className="flex items-center gap-2 text-sm text-danger">
        <AlertCircle size={16} />
        Translation failed
      </div>
      <p className="mt-3 break-words text-sm leading-6 text-content">{message}</p>
    </div>
  );
}
