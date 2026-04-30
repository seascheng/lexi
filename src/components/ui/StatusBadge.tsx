import type { WordStatus } from "../../types";
import { cn } from "../../lib/cn";

const labels: Record<WordStatus, string> = {
  new: "New",
  learning: "Learning",
  mastered: "Mastered",
};

const colors: Record<WordStatus, string> = {
  new: "border-accent/40 bg-accent/10 text-accent",
  learning: "border-warning/40 bg-warning/10 text-warning",
  mastered: "border-muted/40 bg-muted/10 text-muted",
};

export function StatusBadge({ status, className }: { status: WordStatus; className?: string }) {
  return (
    <span className={cn("rounded-full border px-2 py-0.5 text-[11px] font-medium", colors[status], className)}>
      {labels[status]}
    </span>
  );
}
