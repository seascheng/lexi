import {
  ChevronDown,
  ChevronRight,
  Download,
  Search,
  Trash2,
} from "lucide-react";
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
const statuses: Array<"all" | WordStatus> = [
  "all",
  "new",
  "learning",
  "mastered",
];
const entryTypes: Array<"all" | LearningEntryType> = [
  "all",
  "word",
  "phrase",
  "pattern",
];

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
  const pageWords = filteredWords.slice(
    (safeCurrentPage - 1) * PAGE_SIZE,
    safeCurrentPage * PAGE_SIZE,
  );

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
          <h2 className="text-[15px] font-semibold">Vocabulary</h2>
          <p className="text-xs text-muted">
            {filteredWords.length} of {words.length} entries
          </p>
        </div>
        <div className="flex flex-col gap-1.5 sm:flex-row sm:flex-wrap">
          <div className="relative">
            <Search
              className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-muted"
              size={14}
            />
            <Input
              className="w-56 pl-8"
              onChange={(event) => {
                setQuery(event.target.value);
                resetPage();
              }}
              placeholder="Search vocabulary or meaning"
              value={query}
            />
          </div>
          <Select
            onChange={(event) => {
              setEntryType(event.target.value as "all" | LearningEntryType);
              resetPage();
            }}
            value={entryType}
          >
            {entryTypes.map((t) => (
              <option key={t} value={t}>
                {t === "all" ? "All types" : entryTypeLabel(t)}
              </option>
            ))}
          </Select>
          <Select
            onChange={(event) => {
              setStatus(event.target.value as "all" | WordStatus);
              resetPage();
            }}
            value={status}
          >
            {statuses.map((s) => (
              <option key={s} value={s}>
                {s === "all" ? "All statuses" : s}
              </option>
            ))}
          </Select>
          <Button
            onClick={() => exportWords(filteredWords, "json")}
            icon={<Download size={14} />}
          >
            JSON
          </Button>
          <Button
            onClick={() => exportWords(filteredWords, "csv")}
            icon={<Download size={14} />}
          >
            CSV
          </Button>
        </div>
      </div>

      {/* Content */}
      <div className="min-h-0 overflow-y-auto">
        <div className="divide-y divide-border/40">
          {pageWords.map((word) => {
            const isExpanded = expandedId === word.id;
            return (
              <div
                key={word.id}
                className={cn("group transition-colors", isExpanded ? "bg-strong/5" : "hover:bg-strong/5")}
              >
                {/* Collapsed row */}
                <div className="grid w-full grid-cols-[1fr_auto_auto] items-center gap-2.5 px-3 py-1.5 text-left">
                  <button
                    className="flex min-w-0 items-center gap-1.5 py-0.5"
                    onClick={() => toggleExpand(word.id)}
                    type="button"
                  >
                    {isExpanded ? (
                      <ChevronDown size={13} className="shrink-0 text-muted" />
                    ) : (
                      <ChevronRight size={13} className="shrink-0 text-muted" />
                    )}
                    <span className="truncate text-[13px] font-medium text-strong">
                      {word.word}
                    </span>
                    {word.translation ? (
                      <MarkdownRenderer
                        compact
                        inline
                        content={word.translation}
                        className="min-w-0 truncate text-left text-xs text-muted"
                      />
                    ) : null}
                  </button>
                  <StatusBadge status={word.status} className="min-w-[72px] justify-center" />
                  <Button
                    aria-label="Delete"
                    onClick={() => removeWord(word.id)}
                    variant="ghost"
                    icon={<Trash2 size={13} />}
                    className="h-6 min-h-6 w-6 px-0 text-muted/50 opacity-0 transition-opacity hover:text-red-500 group-hover:opacity-100"
                  />
                </div>

                {/* Expanded detail */}
                {isExpanded ? (
                  <div className="grid gap-2 px-3 pb-3 pt-1 md:pl-[30px]">
                    {word.note ? (
                      <MarkdownRenderer content={word.note} compact className="text-[13px] leading-relaxed" />
                    ) : (
                      <div className="grid gap-1">
                        {word.pos ? (
                          <span className="text-[11px] font-medium uppercase tracking-wide text-muted">{word.pos}</span>
                        ) : null}
                        {word.translation ? (
                          <div className="text-[13px] leading-snug text-content/90">{word.translation}</div>
                        ) : null}
                        {word.definition ? (
                          <div className="text-[13px] leading-snug text-content/75">{word.definition}</div>
                        ) : null}
                      </div>
                    )}
                    {word.example ? (
                      <div className="rounded-md bg-example px-3 py-2 text-xs leading-relaxed text-content/70">
                        <span className="mr-0.5 text-muted">“</span>
                        {word.example}
                        <span className="ml-0.5 text-muted">”</span>
                      </div>
                    ) : null}
                    <div className="flex flex-col gap-2 pt-1 sm:flex-row sm:items-center sm:justify-between">
                      <div className="flex flex-wrap gap-3 text-[11px] text-muted">
                        <span>Reviews {word.review_count}</span>
                        <span>Next {formatDate(word.next_review)}</span>
                        <span>Added {formatDate(word.created_at)}</span>
                      </div>
                      <div className="flex items-center gap-2">
                        <StatusTags
                          status={word.status}
                          onStatusChange={(nextStatus) =>
                            changeStatus(word.id, nextStatus)
                          }
                        />
                        <Button
                          aria-label="Delete"
                          onClick={() => removeWord(word.id)}
                          variant="ghost"
                          icon={<Trash2 size={13} />}
                          className="h-6 min-h-6 w-6 px-0 text-muted/70 hover:text-red-500"
                        />
                      </div>
                    </div>
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>

        {pageWords.length === 0 ? (
          <div className="px-3 py-8 text-center text-[13px] text-muted">
            No matching learning entries.
          </div>
        ) : null}

        {/* Pagination */}
        {totalPages > 1 ? (
          <div className="flex items-center justify-center gap-3 border-t border-border/40 py-2 text-[13px]">
            <Button
              disabled={safeCurrentPage <= 1}
              onClick={() => {
                setCurrentPage((p) => p - 1);
                setExpandedId(null);
              }}
              variant="ghost"
              className="h-6 text-xs"
            >
              Prev
            </Button>
            <span className="min-w-[60px] text-center text-xs text-muted">
              {safeCurrentPage} / {totalPages}
            </span>
            <Button
              disabled={safeCurrentPage >= totalPages}
              onClick={() => {
                setCurrentPage((p) => p + 1);
                setExpandedId(null);
              }}
              variant="ghost"
              className="h-6 text-xs"
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
    <div className="flex gap-0.5 rounded-md bg-strong/5 p-0.5">
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
          {entryStatus === "new"
            ? "New"
            : entryStatus === "learning"
              ? "Learning"
              : "Mastered"}
        </button>
      ))}
    </div>
  );
}
