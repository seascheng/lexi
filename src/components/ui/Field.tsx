import { ChevronDown } from "lucide-react";
import type { InputHTMLAttributes, ReactNode, SelectHTMLAttributes, TextareaHTMLAttributes } from "react";
import { cn } from "../../lib/cn";

interface FieldProps {
  label: string;
  children: ReactNode;
  hint?: string;
  /** When true, renders a horizontal settings-row (label left, control right) instead of stacked. */
  inline?: boolean;
  className?: string;
}

export function Field({ label, children, hint, inline, className }: FieldProps) {
  if (inline) {
    return (
      <div className={cn("flex h-14 items-center justify-between gap-3 px-4", className)}>
        <div className="min-w-0">
          <div className="truncate text-[13px] font-medium text-strong">{label}</div>
          {hint ? <div className="mt-0.5 truncate text-[11px] leading-relaxed text-muted">{hint}</div> : null}
        </div>
        <div className="shrink-0">{children}</div>
      </div>
    );
  }
  return (
    <label className={cn("grid gap-1.5 px-4 py-3 text-sm text-strong", className)}>
      <span className="font-medium">{label}</span>
      {children}
      {hint ? <span className="text-xs leading-relaxed text-muted">{hint}</span> : null}
    </label>
  );
}

export function Input({ className, ...props }: InputHTMLAttributes<HTMLInputElement>) {
  return (
    <input
      className={cn(
        "h-[30px] rounded-md border border-border bg-input px-2.5 text-sm text-strong outline-none transition placeholder:text-muted focus:border-accent",
        className,
      )}
      {...props}
    />
  );
}

export function Textarea({ className, ...props }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return (
    <textarea
      className={cn(
        "min-h-20 rounded-md border border-border bg-input px-2.5 py-2 text-sm text-strong outline-none transition placeholder:text-muted focus:border-accent",
        className,
      )}
      {...props}
    />
  );
}

export function Select({ className, children, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <div className="relative inline-flex">
      <select
        className={cn(
          "h-[30px] cursor-pointer appearance-none rounded-md border border-border bg-transparent pl-2.5 pr-7 text-sm text-strong outline-none transition hover:border-strong/40 focus:border-accent",
          className,
        )}
        {...props}
      >
        {children}
      </select>
      <ChevronDown
        aria-hidden
        className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-muted"
        size={12}
        strokeWidth={2.25}
      />
    </div>
  );
}

/** Themed toggle: goty's self-painted pill — 38×22 track, 18px knob. */
export function ToggleSwitch({
  checked,
  onChange,
}: {
  checked: boolean;
  onChange: (value: boolean) => void;
}) {
  return (
    <button
      className={`relative inline-flex h-[22px] w-[38px] shrink-0 items-center rounded-full transition-colors ${
        checked ? "bg-accent" : "border border-border bg-strong/10"
      }`}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!checked);
      }}
      type="button"
      role="switch"
      aria-checked={checked}
    >
      <span
        className={`absolute h-[18px] w-[18px] rounded-full transition-all ${
          checked ? "left-[18px] bg-accent-foreground" : "left-[2px] bg-strong"
        }`}
      />
    </button>
  );
}

/**
 * Grouped settings section, goty shape: the page heading (+ optional
 * description) sits OUTSIDE the card; rows live in one bordered card,
 * capped at 640px and centered, 12pt corners.
 */
export function SettingsCard({
  title,
  description,
  children,
  className,
}: {
  title: string;
  description?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section className={cn("mx-auto w-full max-w-[640px]", className)}>
      <header>
        <h3 className="text-[17px] font-semibold tracking-tight text-strong">{title}</h3>
        {description ? <p className="mt-1 text-[11.5px] leading-relaxed text-muted">{description}</p> : null}
      </header>
      <div className="mt-4 rounded-xl border border-border bg-panel shadow-sm">{children}</div>
    </section>
  );
}

/** Thin separator between inline field rows inside a SettingsCard (inset 16px). */
export function FieldDivider() {
  return <div className="mx-4 border-t border-border/40" />;
}
