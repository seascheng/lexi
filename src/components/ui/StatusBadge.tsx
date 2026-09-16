import type { WordStatus } from "../../types";
import { cn } from "../../lib/cn";

const labels: Record<WordStatus, string> = {
  new: "New",
  learning: "Learning",
  mastered: "Mastered",
};

const dotStyles: Record<WordStatus, string> = {
  new: "bg-muted",
  learning: "bg-amber-500",
  mastered: "bg-emerald-500",
};

export function StatusBadge({ status, className }: { status: WordStatus; className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-1.5 text-[11px] text-content/70", className)}>
      <span aria-hidden className={cn("size-1.5 shrink-0 rounded-full", dotStyles[status])} />
      {labels[status]}
    </span>
  );
}
