import { ChevronDown, ChevronRight, Download, Search, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import type { LearningEntryType, WordEntry, WordStatus } from "../types";
import { deleteWord, updateWordStatus } from "../lib/database";
import { exportWords } from "../lib/export";
import { formatDate } from "../lib/platform";
import { Button } from "../components/ui/Button";
import { Input, Select } from "../components/ui/Field";
import { MarkdownRenderer } from "../components/ui/MarkdownRenderer";
import { StatusBadge } from "../components/ui/StatusBadge";
import { cn } from "../lib/cn";

interface VocabularyPageProps {
  words: WordEntry[];
  onWordsChanged: () => Promise<void>;
}

const PAGE_SIZE = 30;
const statuses: Array<"all" | WordStatus> = ["all", "new", "learning", "mastered"];
const entryTypes: Array<"all" | LearningEntryType> = ["all", "word", "phrase", "pattern"];

function buildDetailMarkdown(word: WordEntry): string {
  const parts: string[] = [];
  if (word.pos) parts.push(`*${word.pos}*`);
  if (word.translation) parts.push(`**${word.translation}**`);
  if (word.definition) parts.push(word.definition);
  if (word.example) parts.push(`> "${word.example}"`);
  if (word.note) parts.push(`---\n${word.note}`);
  return parts.join("\n\n");
}

export function VocabularyPage({ words, onWordsChanged }: VocabularyPageProps) {
  const [query, setQuery] = useState("");
  const [status, setStatus] = useState<"all" | WordStatus>("all");
  const [entryType, setEntryType] = useState<"all" | LearningEntryType>("all");
  const [currentPage, setCurrentPage] = useState(1);
  const [expandedId, setExpandedId] = useState<number | null>(null);

  const filteredWords = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return words.filter((word) => {
      const matchesStatus = status === "all" || word.status === status;
      const matchesType = entryType === "all" || word.entry_type === entryType;
      const matchesQuery =
        !normalizedQuery ||
        word.word.toLowerCase().includes(normalizedQuery) ||
        word.translation.toLowerCase().includes(normalizedQuery) ||
        (word.note ?? "").toLowerCase().includes(normalizedQuery);
      return matchesStatus && matchesType && matchesQuery;
    });
  }, [query, status, entryType, words]);

  const totalPages = Math.max(1, Math.ceil(filteredWords.length / PAGE_SIZE));
  const safeCurrentPage = Math.min(currentPage, totalPages);
  const pageWords = filteredWords.slice((safeCurrentPage - 1) * PAGE_SIZE, safeCurrentPage * PAGE_SIZE);

  function resetPage() {
    setCurrentPage(1);
    setExpandedId(null);
  }

  async function removeWord(id: number) {
    await deleteWord(id);
    await onWordsChanged();
  }

  async function changeStatus(id: number, nextStatus: WordStatus) {
    await updateWordStatus(id, nextStatus);
    await onWordsChanged();
  }

  function toggleExpand(id: number) {
    setExpandedId((current) => (current === id ? null : id));
  }

  return (
    <div className="grid h-full min-h-0 grid-rows-[auto_1fr] gap-2.5">
      {/* Toolbar */}
      <div className="flex flex-col gap-2.5 lg:flex-row lg:items-center lg:justify-between">
        <div>
          <h2 className="text-lg font-semibold">Expressions</h2>
          <p className="text-sm text-muted">{filteredWords.length} of {words.length} entries</p>
        </div>
        <div className="flex flex-col gap-1.5 sm:flex-row sm:flex-wrap">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" size={16} />
            <Input
              className="pl-9"
              onChange={(event) => { setQuery(event.target.value); resetPage(); }}
              placeholder="Search expression or meaning"
              value={query}
            />
          </div>
          <Select onChange={(event) => { setEntryType(event.target.value as "all" | LearningEntryType); resetPage(); }} value={entryType}>
            {entryTypes.map((t) => (
              <option key={t} value={t}>{t === "all" ? "All types" : entryTypeLabel(t)}</option>
            ))}
          </Select>
          <Select onChange={(event) => { setStatus(event.target.value as "all" | WordStatus); resetPage(); }} value={status}>
            {statuses.map((s) => (
              <option key={s} value={s}>{s === "all" ? "All statuses" : s}</option>
            ))}
          </Select>
          <Button onClick={() => exportWords(filteredWords, "json")} icon={<Download size={16} />}>JSON</Button>
          <Button onClick={() => exportWords(filteredWords, "csv")} icon={<Download size={16} />}>CSV</Button>
        </div>
      </div>

      {/* Content */}
      <div className="min-h-0 overflow-y-auto rounded-lg border border-border/60">
        {/* Table header */}
        <div className="sticky top-0 z-10 grid grid-cols-[1fr_auto_auto] items-center gap-2 border-b border-border/60 bg-panel/95 px-3 py-1.5 text-[11px] font-medium uppercase tracking-wider text-muted backdrop-blur">
          <span>Expression</span>
          <span className="w-20 text-center">Status</span>
          <span className="w-8" />
        </div>

        {/* Rows */}
        <div className="divide-y divide-border/40">
          {pageWords.map((word, index) => {
            const isExpanded = expandedId === word.id;
            return (
              <div
                key={word.id}
                className={cn(
                  "transition-colors",
                  index % 2 === 1 ? "bg-surface/20" : "",
                  isExpanded ? "bg-surface/40" : "hover:bg-surface/30",
                )}
              >
                {/* Collapsed row */}
                <div
                  className="grid w-full grid-cols-[1fr_auto_auto] items-center gap-2 px-3 py-2 text-left"
                >
                  <button
                    className="flex min-w-0 items-center gap-2 truncate"
                    onClick={() => toggleExpand(word.id)}
                    type="button"
                  >
                    {isExpanded ? <ChevronDown size={14} className="shrink-0 text-muted" /> : <ChevronRight size={14} className="shrink-0 text-muted" />}
                    <span className="truncate font-medium text-strong">{word.word}</span>
                    <span className="truncate text-sm text-content/70">{word.translation}</span>
                  </button>
                  <span className="w-20 flex justify-center"><StatusBadge status={word.status} /></span>
                  <Button aria-label="Delete" onClick={() => removeWord(word.id)} variant="ghost" icon={<Trash2 size={14} />} className="h-6 min-h-6 w-6 px-0 text-muted/50 hover:text-red-500" />
                </div>

                {/* Expanded detail */}
                {isExpanded ? (
                  <div className="grid gap-2 px-3 pb-3 pt-1">
                    <MarkdownRenderer content={buildDetailMarkdown(word)} />
                    <div className="flex flex-col gap-2 pt-1 sm:flex-row sm:items-center sm:justify-between">
                      <div className="flex flex-wrap gap-3 text-[11px] text-muted">
                        <span>Reviews {word.review_count}</span>
                        <span>Next {formatDate(word.next_review)}</span>
                        <span>Added {formatDate(word.created_at)}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <StatusTags status={word.status} onStatusChange={(nextStatus) => changeStatus(word.id, nextStatus)} />
                        <Button aria-label="Delete" onClick={() => removeWord(word.id)} variant="danger" icon={<Trash2 size={14} />} className="h-7 min-h-7 w-7 px-0" />
                      </div>
                    </div>
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>

        {pageWords.length === 0 ? (
          <div className="px-3 py-6 text-center text-sm text-muted">No matching learning entries.</div>
        ) : null}

        {/* Pagination */}
        {totalPages > 1 ? (
          <div className="flex items-center justify-center gap-3 border-t border-border/40 py-2.5 text-sm">
            <Button
              disabled={safeCurrentPage <= 1}
              onClick={() => { setCurrentPage((p) => p - 1); setExpandedId(null); }}
              variant="ghost"
              className="text-xs"
            >
              Prev
            </Button>
            <span className="min-w-[60px] text-center text-xs text-muted">
              {safeCurrentPage} / {totalPages}
            </span>
            <Button
              disabled={safeCurrentPage >= totalPages}
              onClick={() => { setCurrentPage((p) => p + 1); setExpandedId(null); }}
              variant="ghost"
              className="text-xs"
            >
              Next
            </Button>
          </div>
        ) : null}
      </div>
    </div>
  );
}

function entryTypeLabel(type: LearningEntryType) {
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
    <div className="flex gap-0.5 rounded-md bg-surface/50 p-0.5">
      {(["new", "learning", "mastered"] as WordStatus[]).map((entryStatus) => (
        <button
          className={cn(
            "rounded px-2 py-0.5 text-[11px] font-medium transition",
            status === entryStatus
              ? "bg-panel text-strong shadow-sm"
              : "text-muted hover:text-strong",
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
