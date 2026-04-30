import { BookPlus, Clipboard } from "lucide-react";
import type { TranslationResult } from "../../types";
import { Button } from "../ui/Button";
import { Card } from "../ui/Card";
import { copyTranslation } from "../../lib/translation";

interface TranslationResultPanelProps {
  result: TranslationResult;
  compact?: boolean;
  onSave?: () => void;
}

export function TranslationResultPanel({
  result,
  compact,
  onSave,
}: TranslationResultPanelProps) {
  const content = (
    <TranslationResultContent compact={compact} onSave={onSave} result={result} />
  );

  if (compact) {
    return content;
  }

  return <Card>{content}</Card>;
}

interface TranslationResultContentProps {
  result: TranslationResult;
  compact?: boolean;
  onSave?: () => void;
}

function TranslationResultContent({ result, compact, onSave }: TranslationResultContentProps) {
  if (compact) {
    return (
      <>
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <p className="break-words text-xl font-semibold text-strong">{result.translation}</p>
            {result.pos ? (
              <span className="rounded-full border border-strong/10 bg-surface px-2 py-0.5 text-xs text-muted">
                {result.pos}
              </span>
            ) : null}
          </div>
        </div>

        <p className="mt-3 text-sm leading-6 text-content">{result.definition}</p>
        <p className="mt-3 rounded-xl border border-strong/10 bg-example p-3 text-sm leading-6 text-muted">
          {result.example}
        </p>
      </>
    );
  }

  return (
    <>
      <div className="flex items-start gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="break-words text-3xl font-semibold">
              {result.word}
            </h2>
            {result.pos ? (
              <span className="rounded-full border border-border px-2 py-1 text-xs text-muted">
                {result.pos}
              </span>
            ) : null}
          </div>
          <p className="mt-2 text-lg font-medium text-accent">{result.translation}</p>
        </div>
      </div>

      <p className="mt-4 text-sm leading-6 text-content">{result.definition}</p>
      <p className="mt-3 rounded-md border border-border bg-example p-3 text-sm leading-6 text-muted">
        {result.example}
      </p>

      {!compact ? <div className="mt-4 flex flex-wrap gap-2">
        {onSave ? (
          <Button onClick={onSave} variant="primary" icon={<BookPlus size={16} />}>
            Save
          </Button>
        ) : null}
        <Button onClick={() => copyTranslation(result)} icon={<Clipboard size={16} />}>
          Copy
        </Button>
      </div> : null}
    </>
  );
}
