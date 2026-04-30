import type { MouseEvent, ReactNode, RefObject } from "react";
import { X } from "lucide-react";
import { cn } from "../../lib/cn";
import { Button } from "../ui/Button";

interface FloatingFrameProps {
  children: ReactNode;
  className?: string;
  contentRef?: RefObject<HTMLDivElement>;
  onClose?: () => void;
  onStartDrag?: () => void | Promise<void>;
}

export function FloatingFrame({ children, className, contentRef, onClose, onStartDrag }: FloatingFrameProps) {
  function handleDragMouseDown(event: MouseEvent<HTMLDivElement>) {
    if (!onStartDrag || event.button !== 0) return;
    void onStartDrag();
  }

  return (
    <section
      className={cn(
        "translation-frame relative flex h-full min-h-full flex-col overflow-hidden rounded-[22px] border border-strong/10 bg-floating p-3 text-sm text-muted",
        className,
      )}
    >
      <div
        aria-hidden="true"
        className="absolute left-4 right-12 top-2 z-20 h-7 cursor-grab active:cursor-grabbing"
        data-tauri-drag-region
        onMouseDown={handleDragMouseDown}
      />
      {onClose ? (
        <Button
          aria-label="Close"
          className="absolute right-3 top-3 z-20 h-7 min-h-7 w-7 rounded-full bg-transparent px-0 text-muted hover:bg-surface hover:text-strong"
          icon={<X size={16} />}
          onClick={onClose}
          variant="ghost"
        />
      ) : null}
      <div ref={contentRef} className="relative z-10 flex min-h-0 flex-col pt-8">
        {children}
      </div>
    </section>
  );
}
