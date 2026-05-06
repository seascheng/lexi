import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "../../lib/cn";

interface MarkdownRendererProps {
  content: string;
  className?: string;
  compact?: boolean;
  inline?: boolean;
}

export function MarkdownRenderer({ content, className, compact = false, inline = false }: MarkdownRendererProps) {
  return (
    <div
      className={cn(
        "markdown-renderer min-w-0 text-sm leading-5 text-content",
        compact ? "markdown-renderer-compact" : "markdown-renderer-normal",
        inline && "markdown-renderer-inline",
        className,
      )}
    >
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: ({ className: linkClassName, ...props }) => (
            <a className={cn("text-accent underline underline-offset-2", linkClassName)} {...props} />
          ),
          blockquote: ({ className: quoteClassName, ...props }) => (
            <blockquote className={cn("border-l border-strong/20 pl-3 text-muted", quoteClassName)} {...props} />
          ),
          code: ({ className: codeClassName, ...props }) => (
            <code className={cn("rounded bg-strong/10 px-1 py-0.5 text-[0.92em] text-strong", codeClassName)} {...props} />
          ),
          pre: ({ className: preClassName, ...props }) => (
            <pre className={cn("overflow-x-auto rounded-md border border-strong/10 bg-example p-2 text-xs leading-5 text-content", preClassName)} {...props} />
          ),
          table: ({ className: tableClassName, ...props }) => (
            <div className="overflow-x-auto">
              <table className={cn("w-full border-collapse text-left text-xs", tableClassName)} {...props} />
            </div>
          ),
          th: ({ className: thClassName, ...props }) => (
            <th className={cn("border border-border/60 bg-surface px-2 py-1 font-semibold text-strong", thClassName)} {...props} />
          ),
          td: ({ className: tdClassName, ...props }) => (
            <td className={cn("border border-border/50 px-2 py-1 align-top", tdClassName)} {...props} />
          ),
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}
