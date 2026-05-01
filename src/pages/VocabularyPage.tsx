import { Download, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import type { WordEntry, WordStatus } from "../types";
import { deleteWord, updateWordStatus } from "../lib/database";
import { exportWords } from "../lib/export";
import { formatDate } from "../lib/platform";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { Input, Select } from "../components/ui/Field";
import { StatusBadge } from "../components/ui/StatusBadge";
import { cn } from "../lib/cn";

interface VocabularyPageProps {
  words: WordEntry[];
  onWordsChanged: () => Promise<void>;
}

const statuses: Array<"all" | WordStatus> = ["all", "new", "learning", "mastered"];

export function VocabularyPage({ words, onWordsChanged }: VocabularyPageProps) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<"all" | WordStatus>("all");

  const filteredWords = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return words.filter((word) => {
      const matchesStatus = status === "all" || word.status === status;
      const matchesQuery =
        !normalizedQuery ||
        word.word.toLowerCase().includes(normalizedQuery) ||
        word.translation.toLowerCase().includes(normalizedQuery) ||
        (word.note ?? "").toLowerCase().includes(normalizedQuery);
      return matchesStatus && matchesQuery;
    });
  }, [query, status, words]);

  async function removeWord(id: number) {
    await deleteWord(id);
    await onWordsChanged();
  }

  async function changeStatus(id: number, nextStatus: WordStatus) {
    await updateWordStatus(id, nextStatus);
    await onWordsChanged();
  }

  return (
    <div className="grid min-h-0 grid-rows-[auto_1fr] gap-2.5">
      <Card className="sticky top-0 z-10 flex flex-col gap-2.5 border-border/80 bg-panel/95 backdrop-blur lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h2 className="text-lg font-semibold">Expressions</h2>
          <p className="text-sm text-muted">{filteredWords.length} of {words.length} entries</p>
        </div>
        <div className="flex flex-col gap-1.5 sm:flex-row sm:flex-wrap">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" size={16} />
            <Input
              className="pl-9"
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search expression or meaning"
              value={query}
            />
          </div>
          <Select onChange={(event) => setStatus(event.target.value as "all" | WordStatus)} value={status}>
            {statuses.map((entryStatus) => (
              <option key={entryStatus} value={entryStatus}>
                {entryStatus === "all" ? "All statuses" : entryStatus}
              </option>
            ))}
          </Select>
          <Button onClick={() => exportWords(filteredWords, "json")} icon={<Download size={16} />}>JSON</Button>
          <Button onClick={() => exportWords(filteredWords, "csv")} icon={<Download size={16} />}>CSV</Button>
        </div>
      </Card>

      <div className="min-h-0 overflow-y-auto pr-1">
        <div className="grid gap-1.5">
        {filteredWords.map((word) => (
          <Card className="grid gap-2 p-2.5" key={word.id}>
            <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="break-words text-base font-semibold">{word.word}</h3>
                  <span className="rounded-full border border-border px-1.5 py-0.5 text-[11px] uppercase text-muted">
                    {entryTypeLabel(word.entry_type)}
                  </span>
                  <StatusBadge status={word.status} />
                  {word.pos ? <span className="text-xs text-muted">{word.pos}</span> : null}
                </div>
                <p className="mt-0.5 text-sm font-medium text-strong">{word.translation}</p>
                <p className="mt-0.5 text-sm leading-5 text-content">{word.definition}</p>
                <p className="mt-0.5 text-xs leading-5 text-muted">{word.example}</p>
                {word.note ? (
                  <p className="mt-1 rounded-md border border-border bg-example p-2 text-xs leading-5 text-muted">
                    {word.note}
                  </p>
                ) : null}
              </div>
              <div className="flex shrink-0 flex-wrap items-start gap-2">
                <StatusTags status={word.status} onStatusChange={(nextStatus) => changeStatus(word.id, nextStatus)} />
                <Button aria-label="Delete word" onClick={() => removeWord(word.id)} variant="danger" icon={<Trash2 size={16} />} />
              </div>
            </div>
            <div className="grid gap-1 border-t border-border pt-1.5 text-[11px] text-muted sm:grid-cols-4">
              <span>Type {entryTypeLabel(word.entry_type)}</span>
              <span>Reviews {word.review_count}</span>
              <span>Next {formatDate(word.next_review)}</span>
              <span>Added {formatDate(word.created_at)}</span>
            </div>
          </Card>
        ))}

        {filteredWords.length === 0 ? (
          <Card className="text-center text-sm text-muted">No matching learning entries.</Card>
        ) : null}
        </div>
      </div>
    </div>
  );
}

function entryTypeLabel(type: WordEntry["entry_type"]) {
  if (type === "pattern") return "Pattern";
  if (type === "phrase") return "Phrase";
  return "Word";
}

function StatusTags({
  status,
  onStatusChange,
}: {
  status: WordStatus;
  onStatusChange: (status: WordStatus) => void;
}) {
  return (
    <div className="flex flex-wrap gap-1 rounded-md border border-border bg-surface p-0.5">
      {(["new", "learning", "mastered"] as WordStatus[]).map((entryStatus) => (
        <button
          className={cn(
            "rounded px-1.5 py-0.5 text-[11px] font-medium transition",
            status === entryStatus
              ? "bg-panel text-strong shadow-sm"
              : "text-muted hover:bg-panel hover:text-strong",
          )}
          key={entryStatus}
          onClick={() => onStatusChange(entryStatus)}
          type="button"
        >
          {entryStatus === "new" ? "New" : entryStatus === "learning" ? "Learning" : "Mastered"}
        </button>
      ))}
    </div>
  );
}
