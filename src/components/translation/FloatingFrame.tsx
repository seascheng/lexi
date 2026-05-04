import type { MouseEvent, ReactNode } from "react";
import { Pin, PinOff, X } from "lucide-react";
import { cn } from "../../lib/cn";
import { Button } from "../ui/Button";
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
  isPinned = true,
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

  return (
    <section
      className={cn(
        "translation-frame relative flex h-full min-h-full flex-col overflow-hidden rounded-[14px] bg-floating px-1 pb-0.5 text-sm text-muted",
        className,
      )}
    >
      <div
        aria-hidden="true"
        className="absolute left-11 right-11 top-2 z-20 h-7 cursor-grab active:cursor-grabbing"
        data-tauri-drag-region
      />
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
      {onClose ? (
        <Button
          aria-label="Hide popup"
          className="absolute left-2.5 top-2.5 z-20 h-7 min-h-7 w-7 rounded-full bg-transparent px-0 text-muted/60 hover:bg-strong/12 hover:text-strong"
          icon={<X size={15} />}
          onClick={() => void onClose()}
          title="Hide popup"
          type="button"
          variant="ghost"
        />
      ) : null}
      {/* Panel Tabs */}
      {panels && panels.filter(p => p.enabled).length > 1 && (
        <div className="absolute left-1/2 top-2 -translate-x-1/2 z-20 flex items-center gap-0.5 rounded-md bg-surface p-0.5">
          {panels.filter(p => p.enabled).map((panel) => (
            <button
              key={panel.id}
              onClick={() => onPanelChange?.(panel.id)}
              className={cn(
                "flex items-center gap-1 rounded px-2 py-0.5 text-xs font-medium transition-colors",
                activePanelId === panel.id
                  ? "bg-accent/20 text-strong"
                  : "text-muted hover:text-strong",
              )}
            >
              <FeatureIcon icon={panel.icon} size={12} />
              {panel.name}
            </button>
          ))}
        </div>
      )}
      {onTogglePin ? (
        <Button
          aria-label={isPinned ? "Unpin popup" : "Pin popup"}
          className="absolute right-2.5 top-2.5 z-20 h-7 min-h-7 w-7 rounded-full bg-transparent px-0 text-muted/60 hover:bg-strong/12 hover:text-strong"
          icon={isPinned ? <Pin size={15} /> : <PinOff size={15} />}
          onClick={onTogglePin}
          title={isPinned ? "Unpin popup" : "Pin popup"}
          variant="ghost"
        />
      ) : null}
      <div className="relative z-10 flex min-h-0 flex-1 flex-col overflow-hidden pt-7">
        {children}
      </div>
    </section>
  );
}
