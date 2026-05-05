import { useRef, useState, useEffect } from "react";
import type { AiFeatureIcon } from "../../types";
import {
  FEATURE_ICON_OPTIONS,
  FeatureIcon,
} from "../../lib/featureIcons";

interface IconPickerProps {
  value: AiFeatureIcon;
  onChange: (icon: AiFeatureIcon) => void;
}

export function IconPicker({ value, onChange }: IconPickerProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function handleMouseDown(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", handleMouseDown);
    return () => document.removeEventListener("mousedown", handleMouseDown);
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="flex h-8 w-full items-center justify-between gap-2 rounded-md border border-border/50 bg-input px-2.5 text-left text-sm text-strong transition hover:border-border"
      >
        <span className="flex items-center gap-2">
          <FeatureIcon icon={value} size={16} />
          <span className="text-muted">
            {FEATURE_ICON_OPTIONS.find((o) => o.value === value)?.label ?? value}
          </span>
        </span>
        <svg
          className={`h-3.5 w-3.5 text-muted transition-transform ${open ? "rotate-180" : ""}`}
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          strokeWidth={2}
        >
          <path d="M6 9l6 6 6-6" />
        </svg>
      </button>

      {open && (
        <div className="absolute z-50 mt-1 grid max-h-72 grid-cols-5 gap-1 overflow-y-auto rounded-lg border border-border/50 bg-surface p-2 shadow-lg">
          {FEATURE_ICON_OPTIONS.map((opt) => (
            <button
              key={opt.value}
              type="button"
              onClick={() => {
                onChange(opt.value);
                setOpen(false);
              }}
              className={`flex flex-col items-center gap-1 rounded-md px-1 py-1.5 text-[10px] transition ${
                value === opt.value
                  ? "bg-accent/20 text-accent"
                  : "text-muted hover:bg-strong/5 hover:text-strong"
              }`}
            >
              <FeatureIcon icon={opt.value} size={18} />
              <span className="truncate w-full text-center leading-tight">
                {opt.label}
              </span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
