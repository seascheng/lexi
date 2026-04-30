import { Check, Eye, RotateCcw } from "lucide-react";
import { useMemo, useState } from "react";
import type { ReviewRating, WordEntry } from "../types";
import { applyReviewUpdate, dueWords } from "../lib/database";
import { scheduleReview } from "../lib/sm2";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";

interface ReviewPageProps {
  words: WordEntry[];
  onWordsChanged: () => Promise<void>;
}

const ratings: Array<{ rating: ReviewRating; label: string; variant: "danger" | "secondary" | "primary" }> = [
  { rating: "again", label: "Again", variant: "danger" },
  { rating: "hard", label: "Hard", variant: "secondary" },
  { rating: "good", label: "Good", variant: "primary" },
  { rating: "easy", label: "Easy", variant: "primary" },
];

export function ReviewPage({ words, onWordsChanged }: ReviewPageProps) {
  const due = useMemo(() => dueWords(words), [words]);
  const [index, setIndex] = useState(0);
  const [isRevealed, setIsRevealed] = useState(false);
  const [completed, setCompleted] = useState(0);
  const currentWord = due[index];
  const isComplete = !currentWord;

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
  }

  if (isComplete) {
    return (
      <Card className="mx-auto max-w-2xl text-center">
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-accent/10 text-accent">
          <Check size={24} />
        </div>
        <h2 className="mt-4 text-2xl font-semibold">Review complete</h2>
        <p className="mt-2 text-muted">{completed === 0 ? "No words are due today." : `${completed} words reviewed.`}</p>
        <Button className="mt-5" onClick={restartSession} icon={<RotateCcw size={16} />}>Refresh</Button>
      </Card>
    );
  }

  return (
    <div className="mx-auto grid max-w-3xl gap-5">
      <div className="flex items-center justify-between text-sm text-muted">
        <span>{index + 1}/{due.length} due</span>
        <span>{completed} completed</span>
      </div>
      <Card className="min-h-[360px] text-center">
        <p className="text-sm uppercase tracking-[0.16em] text-muted">Front</p>
        <h2 className="mt-8 break-words text-4xl font-semibold">{currentWord.word}</h2>

        {isRevealed ? (
          <div className="mt-8 grid gap-4 text-left">
            <div>
              <p className="text-sm text-muted">Translation</p>
              <p className="mt-1 text-2xl font-medium text-accent">{currentWord.translation}</p>
            </div>
            <p className="leading-7 text-content">{currentWord.definition}</p>
            <p className="rounded-md border border-border bg-example p-3 text-sm leading-6 text-muted">
              {currentWord.example}
            </p>
          </div>
        ) : (
          <Button className="mt-10" onClick={() => setIsRevealed(true)} variant="primary" icon={<Eye size={16} />}>
            Reveal
          </Button>
        )}
      </Card>

      {isRevealed ? (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {ratings.map((rating) => (
            <Button key={rating.rating} onClick={() => rateWord(rating.rating)} variant={rating.variant}>
              {rating.label}
            </Button>
          ))}
        </div>
      ) : null}
    </div>
  );
}
