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
      <div className={cn("flex items-center justify-between gap-4 py-2.5", className)}>
        <div className="min-w-0">
          <div className="text-sm font-medium text-strong">{label}</div>
          {hint ? <div className="mt-0.5 text-xs leading-relaxed text-muted">{hint}</div> : null}
        </div>
        <div className="shrink-0">{children}</div>
        </div>
    );
  }
  return (
    <label className={cn("grid gap-1.5 text-sm text-strong", className)}>
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
        "h-9 rounded-md border border-border bg-input px-2.5 text-sm text-strong outline-none transition placeholder:text-muted focus:border-accent",
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

export function Select({ className, ...props }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select
      className={cn(
        "h-9 rounded-md border border-border bg-input px-2.5 text-sm text-strong outline-none transition focus:border-accent",
        className,
      )}
      {...props}
    />
  );
}

/** Grouped settings section: a card with a heading and optional description. */
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
    <section className={cn("rounded-xl border border-border bg-panel p-5 shadow-sm", className)}>
      <header className="mb-1">
        <h3 className="text-sm font-semibold tracking-tight text-strong">{title}</h3>
        {description ? <p className="mt-0.5 text-xs text-muted">{description}</p> : null}
      </header>
      <div className="mt-3">{children}</div>
    </section>
  );
}

/** Thin separator between inline field rows inside a SettingsCard. */
export function FieldDivider() {
  return <div className="border-t border-border/40" />;
}
