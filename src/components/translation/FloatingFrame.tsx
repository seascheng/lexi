import type { MouseEvent, ReactNode } from "react";
import { Pin, PinOff, X } from "lucide-react";
import { cn } from "../../lib/cn";
import { FeatureIcon } from "../../lib/featureIcons";
import type { Panel } from "../../types";

export type PopupResizeDirection =
  | "East"
  | "North"
  | "NorthEast"
  | "NorthWest"
  | "South"
  | "SouthEast"
  | "SouthWest"
  | "West";

export interface PopupResizeStart {
  direction: PopupResizeDirection;
  screenX: number;
  screenY: number;
}

interface FloatingFrameProps {
  children: ReactNode;
  className?: string;
  isPinned?: boolean;
  panels?: Panel[];
  activePanelId?: string;
  onPanelChange?: (id: string) => void;
  onClose?: () => void | Promise<void>;
  onTogglePin?: () => void;
  onStartResize?: (resize: PopupResizeStart) => void | Promise<void>;
}

export function FloatingFrame({
  children,
  className,
  isPinned = false,
  panels,
  activePanelId,
  onPanelChange,
  onClose,
  onTogglePin,
  onStartResize,
}: FloatingFrameProps) {
  function handleResizeMouseDown(event: MouseEvent<HTMLDivElement>, direction: PopupResizeDirection) {
    if (!onStartResize || event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    void onStartResize({
      direction,
      screenX: event.screenX,
      screenY: event.screenY,
    });
  }

  const enabledPanels = panels?.filter((panel) => panel.enabled) ?? [];

  return (
    <section
      className={cn(
        "translation-frame relative flex h-full min-h-full flex-col overflow-hidden rounded-2xl text-sm text-muted",
        className,
      )}
    >
      {/* Header: close | panel tabs | pin, draggable in the gaps */}
      <header
        className="relative z-20 flex h-9 shrink-0 items-center gap-1 border-b border-border/40 px-1.5"
        data-tauri-drag-region
      >
        {onClose ? (
          <button
            aria-label="Hide popup"
            className="grid h-6 w-6 shrink-0 place-items-center rounded-md text-muted transition-colors hover:bg-surfaceHover hover:text-strong"
            onClick={() => void onClose()}
            title="Hide popup"
            type="button"
          >
            <X size={14} />
          </button>
        ) : null}
        <div className="h-full min-w-2 flex-1" data-tauri-drag-region />
        {enabledPanels.length > 1 ? (
          <div className="flex shrink-0 items-center gap-0.5 rounded-md bg-surface/70 p-0.5">
            {enabledPanels.map((panel) => (
              <button
                key={panel.id}
                onClick={() => onPanelChange?.(panel.id)}
                className={cn(
                  "flex items-center gap-1 rounded px-2.5 py-1 text-xs font-medium transition-colors",
                  activePanelId === panel.id
                    ? "bg-accent text-accentForeground"
                    : "text-muted hover:text-strong",
                )}
              >
                <FeatureIcon icon={panel.icon} size={13} />
                {panel.name}
              </button>
            ))}
          </div>
        ) : null}
        <div className="h-full min-w-2 flex-1" data-tauri-drag-region />
        {onTogglePin ? (
          <button
            aria-label={isPinned ? "Unpin popup" : "Pin popup"}
            className={cn(
              "grid h-6 w-6 shrink-0 place-items-center rounded-md transition-colors hover:bg-surfaceHover",
              isPinned ? "text-strong" : "text-muted hover:text-strong",
            )}
            onClick={onTogglePin}
            title={isPinned ? "Unpin popup" : "Pin popup"}
            type="button"
          >
            {isPinned ? <Pin size={14} /> : <PinOff size={14} />}
          </button>
        ) : null}
      </header>

      {/* Resize handles */}
      {onStartResize ? (
        <>
          <div
            aria-hidden="true"
            className="absolute inset-x-3 top-0 z-30 h-1.5 cursor-n-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "North")}
          />
          <div
            aria-hidden="true"
            className="absolute inset-x-3 bottom-0 z-30 h-1.5 cursor-s-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "South")}
          />
          <div
            aria-hidden="true"
            className="absolute inset-y-3 left-0 z-30 w-1.5 cursor-w-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "West")}
          />
          <div
            aria-hidden="true"
            className="absolute inset-y-3 right-0 z-30 w-1.5 cursor-e-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "East")}
          />
          <div
            aria-hidden="true"
            className="absolute left-0 top-0 z-30 h-4 w-4 cursor-nw-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "NorthWest")}
          />
          <div
            aria-hidden="true"
            className="absolute right-0 top-0 z-30 h-4 w-4 cursor-ne-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "NorthEast")}
          />
          <div
            aria-hidden="true"
            className="absolute bottom-0 left-0 z-30 h-4 w-4 cursor-sw-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "SouthWest")}
          />
          <div
            aria-hidden="true"
            className="absolute bottom-0 right-0 z-30 h-4 w-4 cursor-se-resize"
            onMouseDown={(event) => handleResizeMouseDown(event, "SouthEast")}
          />
        </>
      ) : null}

      {/* Content */}
      <div className="relative z-10 flex min-h-0 flex-1 flex-col overflow-hidden">
        {children}
      </div>
    </section>
  );
}
