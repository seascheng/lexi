import { useState, useMemo } from "react";
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

export function ReviewPanel({ words, onWordsChanged }: ReviewPanelProps) {
  const [revealed, setRevealed] = useState(false);
  const [completed, setCompleted] = useState(0);
  const [currentIdx, setCurrentIdx] = useState(0);

  const due = useMemo(() => dueWords(words), [words]);

  const current = due[currentIdx];

  async function rateWord(rating: ReviewRating) {
    if (!current) return;
    const update = scheduleReview(current, rating);
    await applyReviewUpdate(current.id, update);
    setRevealed(false);
    setCompleted((c) => c + 1);
    setCurrentIdx((i) => i + 1);
    onWordsChanged();
  }

  // Complete state
  if (!current) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center gap-3 px-4 py-8">
        <div className="text-2xl">✓</div>
        <p className="text-sm text-white/60">Review complete</p>
        {completed > 0 && (
          <p className="text-xs text-white/40">{completed} words reviewed</p>
        )}
        {due.length === 0 && completed === 0 && (
          <p className="text-xs text-white/40">No words due for review</p>
        )}
      </div>
    );
  }

  // Active card
  return (
    <div className="flex flex-1 flex-col overflow-hidden">
      {/* Progress bar */}
      <div className="flex items-center gap-2 px-4 pt-3 pb-1">
        <span className="text-[10px] text-white/40">
          {currentIdx + 1}/{due.length}
        </span>
        <div className="h-1 flex-1 rounded-full bg-white/10">
          <div
            className="h-1 rounded-full bg-indigo-500/60 transition-all"
            style={{ width: `${((currentIdx + 1) / due.length) * 100}%` }}
          />
        </div>
      </div>

      {/* Card */}
      <div className="flex flex-1 flex-col gap-3 overflow-y-auto px-4 py-3">
        {/* Front */}
        <div className="flex flex-col items-center gap-1">
          <span className="text-[10px] uppercase tracking-wider text-white/30">Word</span>
          <p className="text-lg font-medium text-white">{current.word}</p>
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
                <span className="text-[10px] uppercase tracking-wider text-white/30">Translation</span>
                <p className="text-sm text-white/80">{current.translation}</p>
              </div>
            )}
            {current.definition && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-white/30">Definition</span>
                <MarkdownRenderer content={current.definition} />
              </div>
            )}
            {current.example && (
              <div>
                <span className="text-[10px] uppercase tracking-wider text-white/30">Example</span>
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
