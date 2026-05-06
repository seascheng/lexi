import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReviewRating, WordEntry } from "../../types";
import { Card } from "../ui/Card";
import { MarkdownRenderer } from "../ui/MarkdownRenderer";

export interface TypingStats {
  accuracy: number;
  totalChars: number;
  correctChars: number;
  wrongChars: number;
  corrections: number;
  durationMs: number;
}

interface TypingChallengeProps {
  word: WordEntry;
  onComplete: (rating: ReviewRating, stats: TypingStats) => void;
  onSkip: () => void;
}

interface CharState {
  char: string;
  status: "pending" | "correct" | "wrong";
}

interface BlankSegment {
  chars: CharState[];
  isBlank: boolean;
  text: string; // original text for display
}

const STOPWORDS = new Set([
  "a", "an", "the", "of", "in", "on", "at", "to", "for", "and", "or", "but",
  "is", "are", "was", "were", "be", "been", "it", "its", "with", "from",
  "by", "as", "that", "this",
]);

const BLANK_RATIO = 0.5;

function generateSegments(word: WordEntry): BlankSegment[] {
  const text = word.word;

  if (word.entry_type === "word") {
    return [{ chars: text.split("").map((c) => ({ char: c, status: "pending" as const })), isBlank: true, text }];
  }

  // phrase / pattern: split into tokens, blank some
  const tokens = text.split(/(\s+)/); // keep whitespace as segments
  const wordTokens = tokens.filter((t) => t.trim().length > 0);
  const nonStopTokens = wordTokens.filter((t) => !STOPWORDS.has(t.toLowerCase()));

  // Determine which indices to blank
  const blankSet = new Set<number>();
  if (nonStopTokens.length > 0) {
    const shuffled = [...nonStopTokens].sort(() => Math.random() - 0.5);
    const blankCount = Math.max(1, Math.min(shuffled.length - 1, Math.ceil(shuffled.length * BLANK_RATIO)));
    for (let i = 0; i < blankCount; i++) {
      blankSet.add(shuffled[i].length); // temp — use the actual token
    }
    // Rebuild blankSet using token text as key
    blankSet.clear();
    for (let i = 0; i < blankCount; i++) {
      blankSet.add(wordTokens.indexOf(shuffled[i]));
    }
  } else if (wordTokens.length > 0) {
    blankSet.add(0);
  }

  return tokens.map((token) => {
    if (!token.trim()) {
      // whitespace — show as-is
      return { chars: [], isBlank: false, text: token };
    }
    const tokenIdx = wordTokens.indexOf(token);
    const isBlank = blankSet.has(tokenIdx);
    return {
      chars: token.split("").map((c) => ({ char: c, status: "pending" as const })),
      isBlank,
      text: token,
    };
  });
}

// Flatten all blank chars into a single sequence for cursor tracking
function getBlankCharSequence(segments: BlankSegment[]): { segmentIdx: number; charIdx: number; char: string }[] {
  const seq: { segmentIdx: number; charIdx: number; char: string }[] = [];
  segments.forEach((seg, si) => {
    if (seg.isBlank) {
      seg.chars.forEach((c, ci) => {
        seq.push({ segmentIdx: si, charIdx: ci, char: c.char });
      });
    }
  });
  return seq;
}

function accuracyToRating(accuracy: number): ReviewRating {
  if (accuracy >= 100) return "easy";
  if (accuracy >= 80) return "good";
  if (accuracy >= 50) return "hard";
  return "again";
}

export function TypingChallenge({ word, onComplete, onSkip }: TypingChallengeProps) {
  const segments = useMemo(() => generateSegments(word), [word]);
  const charSequence = useMemo(() => getBlankCharSequence(segments), [segments]);
  const totalChars = charSequence.length;

  const [charStates, setCharStates] = useState(segments);
  const [cursor, setCursor] = useState(0); // index into charSequence
  const [corrections, setCorrections] = useState(0);
  const startTimeRef = useRef<number | null>(null);
  const isCompleteRef = useRef(false);

  // Reset state when word changes
  useEffect(() => {
    const newSegments = generateSegments(word);
    setCharStates(newSegments);
    setCursor(0);
    setCorrections(0);
    startTimeRef.current = null;
    isCompleteRef.current = false;
  }, [word]);

  const finishTyping = useCallback(
    (finalSegments: BlankSegment[], totalCorrections: number) => {
      if (isCompleteRef.current) return;
      isCompleteRef.current = true;

      const finalSeq = getBlankCharSequence(finalSegments);
      const correctChars = finalSeq.filter((c) => {
        const seg = finalSegments[c.segmentIdx];
        return seg.chars[c.charIdx].status === "correct";
      }).length;
      const wrongChars = totalChars - correctChars;
      const accuracy = totalChars > 0 ? Math.round((correctChars / totalChars) * 100) : 0;
      const durationMs = startTimeRef.current ? Date.now() - startTimeRef.current : 0;

      const stats: TypingStats = {
        accuracy,
        totalChars,
        correctChars,
        wrongChars,
        corrections: totalCorrections,
        durationMs,
      };

      onComplete(accuracyToRating(accuracy), stats);
    },
    [totalChars, onComplete],
  );

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (isCompleteRef.current) return;

      // Ignore modifier combos
      if (e.metaKey || e.ctrlKey || e.altKey) return;

      if (e.key === "Backspace") {
        e.preventDefault();
        if (cursor === 0) return;

        const newCursor = cursor - 1;
        const { segmentIdx, charIdx } = charSequence[newCursor];
        setCharStates((prev) => {
          const next: BlankSegment[] = prev.map((seg, i) => {
            if (i !== segmentIdx) return seg;
            return {
              ...seg,
              chars: seg.chars.map((c, j): CharState =>
                j === charIdx ? { char: c.char, status: "pending" } : c,
              ),
            };
          });
          return next;
        });
        setCursor(newCursor);
        setCorrections((c) => c + 1);
        return;
      }

      // Only accept single printable chars
      if (e.key.length !== 1) return;
      if (cursor >= totalChars) return;

      e.preventDefault();

      // Start timer on first keypress
      if (startTimeRef.current === null) {
        startTimeRef.current = Date.now();
      }

      const { segmentIdx, charIdx, char: expected } = charSequence[cursor];
      const isCorrect = e.key === expected;
      const newStatus: CharState["status"] = isCorrect ? "correct" : "wrong";

      setCharStates((prev) => {
        const next: BlankSegment[] = prev.map((seg, i) => {
          if (i !== segmentIdx) return seg;
          return {
            ...seg,
            chars: seg.chars.map((c, j): CharState =>
              j === charIdx ? { char: c.char, status: newStatus } : c,
            ),
          };
        });

        const newCursor = cursor + 1;
        setCursor(newCursor);

        if (newCursor >= totalChars) {
          // Defer finish to avoid state update during render
          setTimeout(() => finishTyping(next, corrections), 0);
        }

        return next;
      });
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [cursor, charSequence, totalChars, finishTyping, corrections]);

  // Find which segment the cursor is in for highlighting
  const activeSegmentIdx = cursor < totalChars ? charSequence[cursor].segmentIdx : -1;

  return (
    <Card className="grid min-h-[340px] content-between gap-4 p-4 sm:p-5">
      {/* Header */}
      <div className="flex items-center justify-between text-xs uppercase tracking-[0.16em] text-muted">
        <span>Typing</span>
        <span>
          {entryTypeLabel(word.entry_type)} / {word.status}
        </span>
      </div>

      {/* Translation prompt */}
      <div className="grid place-items-center gap-2 rounded-lg border border-border bg-surface/60 px-4 py-6">
        <MarkdownRenderer content={word.translation} compact className="text-center text-xl font-semibold text-accent sm:text-2xl [&_*]:text-accent" />
        {word.pos && <p className="text-sm text-muted">{word.pos}</p>}
      </div>

      {/* Typing area */}
      <div className="grid min-h-[72px] place-items-center">
        <div className="flex flex-wrap items-center justify-center gap-x-1 gap-y-2 font-mono text-2xl tracking-wide sm:text-3xl">
          {charStates.map((seg, si) => {
            if (!seg.isBlank) {
              // Visible text (non-blank tokens, whitespace)
              if (!seg.chars.length) {
                return (
                  <span key={si} className="text-strong/60">
                    {seg.text}
                  </span>
                );
              }
              return (
                <span key={si} className="text-strong/60">
                  {seg.text}
                </span>
              );
            }

            // Blank segment
            const isActive = si === activeSegmentIdx;
            return (
              <span
                key={si}
                className={`inline-flex rounded px-0.5 ${isActive ? "bg-accent/10" : ""}`}
              >
                {seg.chars.map((c, ci) => {
                  const globalCursorIdx = charSequence.findIndex(
                    (s) => s.segmentIdx === si && s.charIdx === ci,
                  );
                  const isCurrentChar = globalCursorIdx === cursor;

                  if (c.status === "correct") {
                    return (
                      <span key={ci} className="text-green-500">
                        {c.char}
                      </span>
                    );
                  }
                  if (c.status === "wrong") {
                    return (
                      <span key={ci} className="text-red-500">
                        {c.char}
                      </span>
                    );
                  }
                  // Pending
                  return (
                    <span
                      key={ci}
                      className={`text-muted/40 ${isCurrentChar ? "border-b-2 border-accent animate-pulse" : "border-b border-muted/20"}`}
                    >
                      _
                    </span>
                  );
                })}
              </span>
            );
          })}
        </div>
      </div>

      {/* Skip button */}
      <div className="flex justify-center">
        <button
          onClick={onSkip}
          className="text-sm text-muted transition hover:text-strong"
        >
          放弃 / 查看答案
        </button>
      </div>
    </Card>
  );
}

function entryTypeLabel(type: WordEntry["entry_type"]) {
  if (type === "pattern") return "Pattern";
  if (type === "phrase") return "Phrase";
  return "Word";
}
