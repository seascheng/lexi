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
        word.translation.toLowerCase().includes(normalizedQuery);
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
    <div className="grid gap-3">
      <Card className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h2 className="text-xl font-semibold">Vocabulary</h2>
          <p className="text-sm text-muted">{filteredWords.length} of {words.length} entries</p>
        </div>
        <div className="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" size={16} />
            <Input
              className="pl-9"
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Search word or translation"
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

      <div className="grid gap-2">
        {filteredWords.map((word) => (
          <Card className="grid gap-2 p-3" key={word.id}>
            <div className="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="break-words text-base font-semibold">{word.word}</h3>
                  <StatusBadge status={word.status} />
                  {word.pos ? <span className="text-xs text-muted">{word.pos}</span> : null}
                </div>
                <p className="mt-1 text-sm font-medium text-strong">{word.translation}</p>
                <p className="mt-1 text-sm leading-5 text-content">{word.definition}</p>
                <p className="mt-1 text-xs leading-5 text-muted">{word.example}</p>
              </div>
              <div className="flex shrink-0 flex-wrap gap-2">
                <Select
                  className="w-32"
                  onChange={(event) => changeStatus(word.id, event.target.value as WordStatus)}
                  value={word.status}
                >
                  <option value="new">New</option>
                  <option value="learning">Learning</option>
                  <option value="mastered">Mastered</option>
                </Select>
                <Button aria-label="Delete word" onClick={() => removeWord(word.id)} variant="danger" icon={<Trash2 size={16} />} />
              </div>
            </div>
            <div className="grid gap-1 border-t border-border pt-2 text-[11px] text-muted sm:grid-cols-4">
              <span>Added {formatDate(word.created_at)}</span>
              <span>Reviews {word.review_count}</span>
              <span>Next {formatDate(word.next_review)}</span>
              <span>Ease {word.ease_factor.toFixed(2)} / {word.interval}d</span>
            </div>
          </Card>
        ))}

        {filteredWords.length === 0 ? (
          <Card className="text-center text-sm text-muted">No matching vocabulary entries.</Card>
        ) : null}
      </div>
    </div>
  );
}
