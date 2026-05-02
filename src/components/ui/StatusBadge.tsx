import type { WordStatus } from "../../types";
import { cn } from "../../lib/cn";

const labels: Record<WordStatus, string> = {
  new: "New",
  learning: "Learning",
  mastered: "Mastered",
};

const styles: Record<WordStatus, string> = {
  new: "border-strong/15 bg-strong/5 text-strong",
  learning: "border-strong/25 bg-strong/8 text-strong",
  mastered: "border-muted/30 bg-muted/8 text-muted",
};

export function StatusBadge({ status, className }: { status: WordStatus; className?: string }) {
  return (
    <span className={cn("rounded-full border px-2 py-0.5 text-[11px] font-medium", styles[status], className)}>
      {labels[status]}
    </span>
  );
}
