import { Check, Eye, RotateCcw } from "lucide-react";
import { useMemo, useState } from "react";
import type { ReviewRating, WordEntry } from "../types";
import { applyReviewUpdate, dueWords } from "../lib/database";
import { scheduleReview } from "../lib/sm2";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { MarkdownRenderer } from "../components/ui/MarkdownRenderer";
import { TypingChallenge, type TypingStats } from "../components/review/TypingChallenge";
import { TypingResult } from "../components/review/TypingResult";

interface ReviewPageProps {
  words: WordEntry[];
  onWordsChanged: () => Promise<void>;
}

type ReviewMode = "flashcard" | "typing";
type TypingPhase = "typing" | "result";

const ratings: Array<{ rating: ReviewRating; label: string; variant: "danger" | "secondary" | "primary" }> = [
  { rating: "again", label: "Again", variant: "danger" },
  { rating: "hard", label: "Hard", variant: "secondary" },
  { rating: "good", label: "Good", variant: "primary" },
  { rating: "easy", label: "Easy", variant: "primary" },
];

export function ReviewPage({ words, onWordsChanged }: ReviewPageProps) {
  const due = useMemo(() => dueWords(words), [words]);
  const [index, setIndex] = useState(0);
  const [completed, setCompleted] = useState(0);
  const currentWord = due[index];
  const isComplete = !currentWord;

  // Flashcard state
  const [isRevealed, setIsRevealed] = useState(false);

  // Typing mode state
  const [reviewMode, setReviewMode] = useState<ReviewMode>("flashcard");
  const [typingPhase, setTypingPhase] = useState<TypingPhase>("typing");
  const [typingStats, setTypingStats] = useState<TypingStats | null>(null);
  const [typingRating, setTypingRating] = useState<ReviewRating>("good");

  async function rateWord(rating: ReviewRating) {
    if (!currentWord) return;

    await applyReviewUpdate(currentWord.id, scheduleReview(currentWord, rating));
    setCompleted((count) => count + 1);
    setIsRevealed(false);
    setIndex((nextIndex) => nextIndex + 1);
    await onWordsChanged();
  }

  function restartSession() {
    setCompleted(0);
    setIndex(0);
    setIsRevealed(false);
    setTypingPhase("typing");
    setTypingStats(null);
  }

  function handleTypingComplete(rating: ReviewRating, stats: TypingStats) {
    setTypingStats(stats);
    setTypingRating(rating);
    // Persist immediately but don't advance index yet — show result first
    setTypingPhase("result");
  }

  async function handleTypingSkip() {
    setTypingStats(null);
    setTypingRating("again");
    setTypingPhase("result");
  }

  async function handleTypingNext() {
    // Now persist and advance
    await applyReviewUpdate(currentWord.id, scheduleReview(currentWord, typingRating));
    setCompleted((count) => count + 1);
    setTypingPhase("typing");
    setTypingStats(null);
    setIndex((nextIndex) => nextIndex + 1);
    await onWordsChanged();
  }

  if (isComplete) {
    return (
      <div className="grid min-h-0 grid-rows-[auto_1fr] gap-2.5">
        <ReviewToolbar completed={completed} dueCount={due.length} index={0} reviewMode={reviewMode} onModeChange={setReviewMode} />
        <div className="grid min-h-0 place-items-center overflow-y-auto">
          <Card className="grid min-h-[280px] w-full max-w-3xl place-items-center p-5 text-center">
            <div>
              <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-accent/10 text-accent">
                <Check size={24} />
              </div>
              <h2 className="mt-4 text-2xl font-semibold">Review complete</h2>
              <p className="mt-2 text-muted">{completed === 0 ? "No entries are due today." : `${completed} entries reviewed.`}</p>
              <Button className="mt-5" onClick={restartSession} icon={<RotateCcw size={16} />}>Refresh</Button>
            </div>
          </Card>
        </div>
      </div>
    );
  }

  return (
    <div className="grid min-h-0 grid-rows-[auto_1fr] gap-2.5">
      <ReviewToolbar completed={completed} dueCount={due.length} index={index} reviewMode={reviewMode} onModeChange={setReviewMode} />

      <div className="min-h-0 overflow-y-auto pr-1">
        <div className="mx-auto grid w-full max-w-3xl gap-3">

          {reviewMode === "flashcard" ? (
            <>
              <Card className="grid min-h-[340px] content-between gap-3 p-4 text-center sm:p-5">
                <div className="flex items-center justify-between text-xs uppercase tracking-[0.16em] text-muted">
                  <span>Front</span>
                  <span>{entryTypeLabel(currentWord.entry_type)} / {currentWord.status}</span>
                </div>

                <div className="grid min-h-[120px] place-items-center rounded-lg border border-border bg-surface/60 px-3 py-5">
                  <h2 className="max-w-full break-words text-4xl font-semibold leading-tight text-strong md:text-5xl">
                    {currentWord.word}
                  </h2>
                </div>

                {isRevealed ? (
                  <div className="grid gap-2.5 rounded-lg border border-border bg-example p-3 text-left">
                    <div>
                      <p className="text-sm text-muted">Translation</p>
                      <p className="mt-1 text-xl font-medium text-accent">{currentWord.translation}</p>
                    </div>
                    <MarkdownRenderer content={[currentWord.definition, currentWord.example, currentWord.note].filter(Boolean).join("\n\n")} />
                  </div>
                ) : (
                  <div className="grid min-h-[64px] place-items-center">
                    <Button className="min-w-32" onClick={() => setIsRevealed(true)} variant="primary" icon={<Eye size={16} />}>
                      Reveal
                    </Button>
                  </div>
                )}
              </Card>

              {isRevealed ? (
                <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                  {ratings.map((rating) => (
                    <Button className="min-h-9" key={rating.rating} onClick={() => rateWord(rating.rating)} variant={rating.variant}>
                      {rating.label}
                    </Button>
                  ))}
                </div>
              ) : null}
            </>
          ) : typingPhase === "typing" ? (
            <TypingChallenge
              key={currentWord.id}
              word={currentWord}
              onComplete={handleTypingComplete}
              onSkip={handleTypingSkip}
            />
          ) : (
            <TypingResult
              word={currentWord}
              stats={typingStats}
              rating={typingRating}
              onNext={handleTypingNext}
            />
          )}

        </div>
      </div>
    </div>
  );
}

function ReviewToolbar({
  completed,
  dueCount,
  index,
  reviewMode,
  onModeChange,
}: {
  completed: number;
  dueCount: number;
  index: number;
  reviewMode: ReviewMode;
  onModeChange: (mode: ReviewMode) => void;
}) {
  const current = Math.min(index + 1, Math.max(dueCount, 1));
  const progress = dueCount > 0 ? Math.max(4, Math.round((current / dueCount) * 100)) : 100;

  return (
    <Card className="sticky top-0 z-10 grid gap-2 border-border/80 bg-panel/95 backdrop-blur">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <div>
            <h2 className="text-lg font-semibold">Review</h2>
            <p className="text-sm text-muted">{dueCount} due / {completed} completed</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <ModeToggle mode={reviewMode} onChange={onModeChange} />
          <div className="text-sm text-muted">{dueCount > 0 ? `${current}/${dueCount}` : "0/0"}</div>
        </div>
      </div>
      <div className="h-1.5 overflow-hidden rounded-full bg-surface">
        <div
          className="h-full rounded-full bg-accent transition-[width]"
          style={{ width: `${progress}%` }}
        />
      </div>
    </Card>
  );
}

function ModeToggle({ mode, onChange }: { mode: ReviewMode; onChange: (mode: ReviewMode) => void }) {
  const modes: Array<{ value: ReviewMode; label: string }> = [
    { value: "flashcard", label: "Flashcard" },
    { value: "typing", label: "Typing" },
  ];

  return (
    <div className="flex rounded-md border border-border bg-surface p-0.5">
      {modes.map((m) => (
        <button
          key={m.value}
          onClick={() => onChange(m.value)}
          className={`rounded px-2 py-0.5 text-xs font-medium transition ${
            mode === m.value ? "bg-accent text-accentForeground" : "text-muted hover:text-strong"
          }`}
        >
          {m.label}
        </button>
      ))}
    </div>
  );
}

function entryTypeLabel(type: WordEntry["entry_type"]) {
  if (type === "pattern") return "Pattern";
  if (type === "phrase") return "Phrase";
  return "Word";
}
