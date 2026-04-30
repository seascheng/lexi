import type { ReactNode } from "react";

interface MarkdownRendererProps {
  content: string;
}

type MarkdownBlock =
  | { type: "heading"; level: 1 | 2 | 3; content: string }
  | { type: "paragraph"; content: string }
  | { type: "blockquote"; content: string }
  | { type: "list"; ordered: boolean; items: string[] }
  | { type: "code"; content: string };

export function MarkdownRenderer({ content }: MarkdownRendererProps) {
  const blocks = parseMarkdownBlocks(content);

  return (
    <div className="grid gap-2 text-sm leading-5 text-content">
      {blocks.map((block, index) => renderBlock(block, index))}
    </div>
  );
}

function renderBlock(block: MarkdownBlock, index: number) {
  if (block.type === "heading") {
    const className = block.level === 1
      ? "text-base font-semibold leading-6 text-strong"
      : "text-sm font-semibold leading-5 text-strong";
    const children = renderInlineMarkdown(block.content);
    if (block.level === 1) return <h1 className={className} key={index}>{children}</h1>;
    if (block.level === 2) return <h2 className={className} key={index}>{children}</h2>;
    return <h3 className={className} key={index}>{children}</h3>;
  }

  if (block.type === "blockquote") {
    return (
      <blockquote className="border-l border-strong/20 pl-3 text-muted" key={index}>
        {renderInlineMarkdown(block.content)}
      </blockquote>
    );
  }

  if (block.type === "list") {
    const ListTag = block.ordered ? "ol" : "ul";
    return (
      <ListTag className={`grid gap-1 pl-5 ${block.ordered ? "list-decimal" : "list-disc"}`} key={index}>
        {block.items.map((item, itemIndex) => (
          <li className="break-words" key={`${index}-${itemIndex}`}>
            {renderInlineMarkdown(item)}
          </li>
        ))}
      </ListTag>
    );
  }

  if (block.type === "code") {
    return (
      <pre className="overflow-x-auto rounded-md border border-strong/10 bg-example p-2 text-xs leading-5 text-content" key={index}>
        <code>{block.content}</code>
      </pre>
    );
  }

  return (
    <p className="break-words" key={index}>
      {renderInlineMarkdown(block.content)}
    </p>
  );
}

function parseMarkdownBlocks(content: string): MarkdownBlock[] {
  const lines = content.replace(/\r\n/g, "\n").trim().split("\n");
  const blocks: MarkdownBlock[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();

    if (!trimmed) {
      index += 1;
      continue;
    }

    if (trimmed.startsWith("```")) {
      const codeLines: string[] = [];
      index += 1;
      while (index < lines.length && !lines[index].trim().startsWith("```")) {
        codeLines.push(lines[index]);
        index += 1;
      }
      blocks.push({ type: "code", content: codeLines.join("\n") });
      index += 1;
      continue;
    }

    const heading = /^(#{1,3})\s+(.+)$/.exec(trimmed);
    if (heading) {
      blocks.push({
        type: "heading",
        level: heading[1].length as 1 | 2 | 3,
        content: heading[2],
      });
      index += 1;
      continue;
    }

    if (trimmed.startsWith(">")) {
      const quoteLines: string[] = [];
      while (index < lines.length && lines[index].trim().startsWith(">")) {
        quoteLines.push(lines[index].trim().replace(/^>\s?/, ""));
        index += 1;
      }
      blocks.push({ type: "blockquote", content: quoteLines.join(" ") });
      continue;
    }

    const unorderedList = /^[-*]\s+(.+)$/.exec(trimmed);
    const orderedList = /^\d+\.\s+(.+)$/.exec(trimmed);
    if (unorderedList || orderedList) {
      const ordered = Boolean(orderedList);
      const items: string[] = [];
      while (index < lines.length) {
        const itemMatch = ordered ? /^\d+\.\s+(.+)$/.exec(lines[index].trim()) : /^[-*]\s+(.+)$/.exec(lines[index].trim());
        if (!itemMatch) break;
        items.push(itemMatch[1]);
        index += 1;
      }
      blocks.push({ type: "list", ordered, items });
      continue;
    }

    const paragraphLines: string[] = [];
    while (index < lines.length && lines[index].trim()) {
      const nextLine = lines[index].trim();
      if (
        nextLine.startsWith("```") ||
        /^(#{1,3})\s+/.test(nextLine) ||
        nextLine.startsWith(">") ||
        /^[-*]\s+/.test(nextLine) ||
        /^\d+\.\s+/.test(nextLine)
      ) {
        break;
      }
      paragraphLines.push(nextLine);
      index += 1;
    }
    blocks.push({ type: "paragraph", content: paragraphLines.join(" ") });
  }

  return blocks.length > 0 ? blocks : [{ type: "paragraph", content }];
}

function renderInlineMarkdown(content: string): ReactNode[] {
  const tokens = content.split(/(`[^`]+`|\*\*[^*]+\*\*)/g);
  return tokens.map((token, index) => {
    if (token.startsWith("`") && token.endsWith("`")) {
      return (
        <code className="rounded bg-strong/10 px-1 py-0.5 text-[0.92em] text-strong" key={index}>
          {token.slice(1, -1)}
        </code>
      );
    }

    if (token.startsWith("**") && token.endsWith("**")) {
      return <strong className="font-semibold text-strong" key={index}>{token.slice(2, -2)}</strong>;
    }

    return <span key={index}>{token}</span>;
  });
}
