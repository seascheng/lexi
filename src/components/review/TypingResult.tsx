import { ChevronRight } from "lucide-react";
import type { ReviewRating, WordEntry } from "../../types";
import type { TypingStats } from "./TypingChallenge";
import { Card } from "../ui/Card";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";

interface TypingResultProps {
  word: WordEntry;
  stats: TypingStats | null; // null when skipped
  rating: ReviewRating;
  onNext: () => void;
}

const ratingLabels: Record<ReviewRating, { label: string; color: string }> = {
  easy: { label: "Easy", color: "text-green-500" },
  good: { label: "Good", color: "text-accent" },
  hard: { label: "Hard", color: "text-yellow-500" },
  again: { label: "Again", color: "text-red-500" },
};

function formatDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

export function TypingResult({ word, stats, rating, onNext }: TypingResultProps) {
  const { label, color } = ratingLabels[rating];
  const wasSkipped = stats === null;

  return (
    <Card className="grid min-h-[340px] content-between gap-4 p-4 sm:p-5">
      {/* Answer display */}
      <div className="flex items-center justify-between text-xs uppercase tracking-[0.16em] text-muted">
        <span>Result</span>
        <span className={`${color} font-semibold`}>{label}</span>
      </div>

      {/* Correct answer */}
      <div className="grid place-items-center gap-3 rounded-lg border border-border bg-surface/60 px-4 py-6">
        <p className="text-2xl font-semibold text-strong sm:text-3xl">{word.word}</p>
        <MarkdownRenderer content={word.translation} compact className="text-center text-muted [&_*]:text-muted" />
      </div>

      {/* Stats */}
      {!wasSkipped ? (
        <div className="flex items-center justify-center gap-4 text-sm">
          <span className="text-muted">
            准确率: <span className="font-medium text-strong">{stats.accuracy}%</span>
          </span>
          <span className="text-muted">·</span>
          <span className="text-muted">
            错误: <span className="font-medium text-strong">{stats.wrongChars}</span>
          </span>
          <span className="text-muted">·</span>
          <span className="text-muted">
            用时: <span className="font-medium text-strong">{formatDuration(stats.durationMs)}</span>
          </span>
        </div>
      ) : (
        <div className="flex items-center justify-center text-sm text-muted">
          已跳过
        </div>
      )}

      {/* Definition / Example if available */}
      {word.definition && <MarkdownRenderer content={word.definition} compact className="text-center text-muted [&_*]:text-muted" />}

      {/* Next button */}
      <div className="flex justify-center">
        <button
          onClick={onNext}
          className="inline-flex items-center gap-1.5 rounded-md bg-accent px-4 py-2 text-sm font-medium text-accentForeground transition hover:bg-accentHover"
        >
          下一题
          <ChevronRight size={16} />
        </button>
      </div>
    </Card>
  );
}
