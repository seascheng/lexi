import { useState, useMemo, useEffect, useRef, useCallback } from "react";
import type { WordEntry, ReviewRating } from "../../types";
import { dueWords, applyReviewUpdate } from "../../lib/database";
import { scheduleReview } from "../../lib/sm2";
import { Button } from "../ui/Button";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";
import { StatusBadge } from "../ui/StatusBadge";

interface ReviewPanelProps {
  words: WordEntry[];
  onWordsChanged: () => void;
}

const AUTO_ADVANCE_MS = 30_000;

export function ReviewPanel({ words, onWordsChanged }: ReviewPanelProps) {
  const [revealed, setRevealed] = useState(false);
  const [completed, setCompleted] = useState(0);
  const [currentIdx, setCurrentIdx] = useState(0);
  const [timeLeft, setTimeLeft] = useState(AUTO_ADVANCE_MS);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  const due = useMemo(() => dueWords(words), [words]);
  const current = due[currentIdx];

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearInterval(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  // Auto-advance timer: counts down after reveal
  useEffect(() => {
    clearTimer();
    if (!revealed || !current) return;

    setTimeLeft(AUTO_ADVANCE_MS);
    timerRef.current = setInterval(() => {
      setTimeLeft((t) => {
        if (t <= 1000) {
          clearTimer();
          // Auto-advance with "good" rating
          const update = scheduleReview(due[currentIdx], "good");
          applyReviewUpdate(due[currentIdx].id, update).then(() => {
            setRevealed(false);
            setCompleted((c) => c + 1);
            setCurrentIdx((i) => i + 1);
            setTimeLeft(AUTO_ADVANCE_MS);
            onWordsChanged();
          });
          return 0;
        }
        return t - 1000;
      });
    }, 1000);

    return clearTimer;
  }, [revealed, currentIdx, current]);

  async function rateWord(rating: ReviewRating) {
    if (!current) return;
    clearTimer();
    const update = scheduleReview(current, rating);
    await applyReviewUpdate(current.id, update);
    setRevealed(false);
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
      <div className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-8">
        <div className="text-2xl text-strong">✓</div>
        <p className="text-sm text-muted">Review complete</p>
        {completed > 0 && (
          <p className="text-xs text-muted/60">{completed} words reviewed</p>
        )}
        {due.length === 0 && completed === 0 && (
          <p className="text-xs text-muted/60">No words due for review</p>
        )}
      </div>
    );
  }

  const secondsLeft = Math.ceil(timeLeft / 1000);

  // Active card
  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Progress bar + navigation */}
      <div className="flex items-center gap-2 px-4 pt-3 pb-1">
        <button
          onClick={goBack}
          disabled={currentIdx === 0}
          className="text-muted/60 hover:text-strong disabled:opacity-30 transition-colors text-xs"
        >
          ◀
        </button>
        <span className="text-[10px] text-muted/60">
          {currentIdx + 1}/{due.length}
        </span>
        <div className="h-1 flex-1 rounded-full bg-surface">
          <div
            className="h-1 rounded-full bg-accent/60 transition-all"
            style={{ width: `${((currentIdx + 1) / due.length) * 100}%` }}
          />
        </div>
        <button
          onClick={goForward}
          disabled={currentIdx >= due.length - 1}
          className="text-muted/60 hover:text-strong disabled:opacity-30 transition-colors text-xs"
        >
          ▶
        </button>
        {revealed && (
          <span className="text-[10px] text-muted/60 tabular-nums w-6 text-right">{secondsLeft}s</span>
        )}
      </div>

      {/* Card */}
      <div className="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-3">
        {/* Front */}
        <div className="flex flex-col items-center gap-1">
          <span className="text-[10px] uppercase tracking-wider text-muted/50">Word</span>
          <p className="text-lg font-medium text-strong">{current.word}</p>
          <StatusBadge status={current.status} />
        </div>

        {/* Reveal / Back */}
        {!revealed ? (
          <div className="flex justify-center pt-2">
            <Button variant="ghost" onClick={() => setRevealed(true)}>
              Reveal
            </Button>
          </div>
        ) : (
          <div className="flex flex-col gap-2">
            {current.translation && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-muted/50">Translation</span>
                <p className="text-sm text-content">{current.translation}</p>
              </div>
            )}
            {current.definition && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-muted/50">Definition</span>
                <MarkdownRenderer content={current.definition} />
              </div>
            )}
            {current.example && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-muted/50">Example</span>
                <MarkdownRenderer content={current.example} />
              </div>
            )}

            {/* Rating buttons */}
            <div className="grid grid-cols-4 gap-2 pt-2">
              <Button variant="danger" onClick={() => rateWord("again")}>Again</Button>
              <Button variant="secondary" onClick={() => rateWord("hard")}>Hard</Button>
              <Button variant="primary" onClick={() => rateWord("good")}>Good</Button>
              <Button variant="primary" onClick={() => rateWord("easy")}>Easy</Button>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
