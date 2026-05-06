import { Eye } from "lucide-react";
import { useState, useMemo, useEffect, useRef, useCallback } from "react";
import type { WordEntry, ReviewRating } from "../../types";
import { dueWords, applyReviewUpdate } from "../../lib/database";
import { scheduleReview } from "../../lib/sm2";
import { Button } from "../ui/Button";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";

interface ReviewPanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

const AUTO_ADVANCE_MS = 30_000;

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export function ReviewPanel({ words, onWordsChanged }: ReviewPanelProps) {
  const [revealed, setRevealed] = useState(false);
  const [completed, setCompleted] = useState(0);
  const [currentIdx, setCurrentIdx] = useState(0);
  const [timeLeft, setTimeLeft] = useState(AUTO_ADVANCE_MS);
  const [paused, setPaused] = useState(false);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const due = useMemo(() => shuffle(dueWords(words)), [words]);
  const current = due[currentIdx];

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  // Timer: always counts down unless paused, auto-advance when revealed + time runs out
  useEffect(() => {
    clearTimer();
    if (!current || paused) return;

    timerRef.current = setInterval(() => {
      setTimeLeft((t) => {
        if (t <= 1000) {
          clearTimer();
          if (revealed) {
            const update = scheduleReview(due[currentIdx], "good");
            applyReviewUpdate(due[currentIdx].id, update).then(() => {
              setRevealed(false);
              setCompleted((c) => c + 1);
              setCurrentIdx((i) => i + 1);
              setTimeLeft(AUTO_ADVANCE_MS);
              onWordsChanged();
            });
          } else {
            setTimeLeft(AUTO_ADVANCE_MS);
          }
          return 0;
        }
        return t - 1000;
      });
    }, 1000);

    return clearTimer;
  }, [revealed, currentIdx, current, paused]);

  // Keyboard navigation
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        goBack();
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        goForward();
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  });

  function togglePause() {
    setPaused((p) => !p);
  }

  async function rateWord(rating: ReviewRating) {
    if (!current) return;
    clearTimer();
    const update = scheduleReview(current, rating);
    await applyReviewUpdate(current.id, update);
    setRevealed(false);
    setPaused(false);
    setCompleted((c) => c + 1);
    setCurrentIdx((i) => i + 1);
    setTimeLeft(AUTO_ADVANCE_MS);
    onWordsChanged();
  }

  function goBack() {
    if (currentIdx > 0) {
      clearTimer();
      setRevealed(false);
      setCurrentIdx((i) => i - 1);
      setTimeLeft(AUTO_ADVANCE_MS);
    }
  }

  function goForward() {
    if (currentIdx < due.length - 1) {
      clearTimer();
      setRevealed(false);
      setCurrentIdx((i) => i + 1);
      setTimeLeft(AUTO_ADVANCE_MS);
    }
  }

  // Complete state
  if (!current) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-2 px-4 py-6">
        <div className="text-xl text-strong">✓</div>
        <p className="text-sm text-strong font-medium">Review complete</p>
        {completed > 0 && (
          <p className="text-xs text-muted">{completed} entries reviewed</p>
        )}
        {due.length === 0 && completed === 0 && (
          <p className="text-xs text-muted">No entries are due today</p>
        )}
      </div>
    );
  }

  const secondsLeft = Math.ceil(timeLeft / 1000);
  const progress = due.length > 0 ? Math.max(4, Math.round(((currentIdx + 1) / due.length) * 100)) : 100;

  // Active card
  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Progress bar + navigation */}
      <div className="flex items-center gap-2.5 px-4 pt-3 pb-1.5">
        <button
          onClick={goBack}
          disabled={currentIdx === 0}
          className="text-muted/70 hover:text-strong disabled:opacity-30 transition-colors text-sm px-0.5"
        >
          ◀
        </button>
        <div className="h-3 flex-1 overflow-hidden rounded-full bg-surface">
          <div
            className="h-full rounded-full bg-accent transition-[width]"
            style={{ width: `${progress}%` }}
          />
        </div>
        <button
          onClick={goForward}
          disabled={currentIdx >= due.length - 1}
          className="text-muted/70 hover:text-strong disabled:opacity-30 transition-colors text-sm px-0.5"
        >
          ▶
        </button>
        <button
          onClick={togglePause}
          className="text-xs text-muted/60 tabular-nums w-12 text-right hover:text-strong transition-colors"
        >
          {currentIdx + 1}/{due.length}
          <span className="ml-1">{paused ? "⏸" : `${secondsLeft}s`}</span>
        </button>
      </div>

      {/* Card content */}
      <div className="flex flex-1 flex-col items-center gap-2 overflow-y-auto px-4 py-2">
        {/* Word */}
        <div className="w-full rounded-lg border border-border bg-surface/40 px-3 py-1.5 text-center">
          <div className="flex items-center justify-between text-[10px] uppercase tracking-wider text-muted/50">
            <span>Front</span>
            <span>{entryTypeLabel(current.entry_type)} / {current.status}</span>
          </div>
          <h2 className="text-xl font-semibold text-strong leading-tight break-words py-1">
            {current.word}
          </h2>
        </div>

        {/* Reveal / Answer */}
        {!revealed ? (
          <div className="grid min-h-[40px] place-items-center">
            <Button
              onClick={() => setRevealed(true)}
              variant="primary"
              icon={<Eye size={16} />}
              className="min-w-28"
            >
              Reveal
            </Button>
          </div>
        ) : (
          <div className="w-full flex flex-col gap-2">
            {/* Translation + details */}
            <div className="rounded-lg border border-border bg-surface/30 p-3 text-left">
              {current.translation && (
                <div>
                  <p className="text-xs text-muted">Translation</p>
                  <MarkdownRenderer content={current.translation} className="mt-0.5 text-strong [&_*]:text-strong" />
                </div>
              )}
              <MarkdownRenderer content={[current.definition, current.example, current.note].filter(Boolean).join("\n\n")} />
            </div>

            {/* Rating buttons */}
            <div className="grid grid-cols-4 gap-1.5">
              <Button variant="danger" onClick={() => rateWord("again")} className="min-h-8">Again</Button>
              <Button variant="secondary" onClick={() => rateWord("hard")} className="min-h-8">Hard</Button>
              <Button variant="primary" onClick={() => rateWord("good")} className="min-h-8">Good</Button>
              <Button variant="primary" onClick={() => rateWord("easy")} className="min-h-8">Easy</Button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function entryTypeLabel(type: WordEntry["entry_type"]) {
  if (type === "pattern") return "Pattern";
  if (type === "phrase") return "Phrase";
  return "Word";
}
