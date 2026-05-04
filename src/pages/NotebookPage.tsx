import { Check, Plus, Search, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import type { NoteEntry, TagEntry } from "../types";
import {
  addNote, deleteNote, listNotes, listTags,
  updateNote, setNoteTag,
} from "../lib/database";
import { Button } from "../components/ui/Button";
import { Input, Textarea, Select } from "../components/ui/Field";
import { cn } from "../lib/cn";

const PAGE_SIZE = 30;

export function NotebookPage() {
  const [notes, setNotes] = useState<NoteEntry[]>([]);
  const [tags, setTags] = useState<TagEntry[]>([]);
  const [activeTag, setActiveTag] = useState("all");
  const [query, setQuery] = useState("");
  const [currentPage, setCurrentPage] = useState(1);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [editName, setEditName] = useState("");
  const [editContent, setEditContent] = useState("");

  useEffect(() => {
    void refresh();
  }, []);

  async function refresh() {
    const [n, t] = await Promise.all([listNotes(), listTags()]);
    setNotes(n);
    setTags(t);
  }

  const filteredNotes = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return notes.filter((note) => {
      const matchesTag = activeTag === "all" || note.tags.includes(activeTag);
      const matchesQuery =
        !normalizedQuery ||
        (note.name ?? "").toLowerCase().includes(normalizedQuery) ||
        note.content.toLowerCase().includes(normalizedQuery);
      return matchesTag && matchesQuery;
    });
  }, [notes, activeTag, query]);

  const totalPages = Math.max(1, Math.ceil(filteredNotes.length / PAGE_SIZE));
  const safeCurrentPage = Math.min(currentPage, totalPages);
  const pageNotes = filteredNotes.slice((safeCurrentPage - 1) * PAGE_SIZE, safeCurrentPage * PAGE_SIZE);

  function resetPage() {
    setCurrentPage(1);
    setEditingId(null);
  }

  // ── Note actions ───────────────────────────────────

  async function handleAddNote() {
    await addNote({ content: "New note" });
    await refresh();
    const fresh = await listNotes();
    if (fresh.length > 0) {
      startEdit(fresh[0]);
    }
  }

  async function handleDeleteNote(id: number) {
    await deleteNote(id);
    if (editingId === id) setEditingId(null);
    await refresh();
  }

  async function handleSaveEdit() {
    if (editingId === null) return;
    await updateNote(editingId, { name: editName || null, content: editContent });
    setEditingId(null);
    await refresh();
  }

  function startEdit(note: NoteEntry) {
    setEditingId(note.id);
    setEditName(note.name ?? "");
    setEditContent(note.content);
  }

  function cancelEdit() {
    setEditingId(null);
  }

  async function handleChangeTag(noteId: number, tagName: string) {
    if (tagName === "none") return;
    await setNoteTag(noteId, tagName);
    await refresh();
  }

  return (
    <div className="flex h-full min-h-0 flex-col gap-2.5">
      {/* Toolbar */}
      <div className="flex items-center justify-between gap-2.5">
        <div>
          <h2 className="text-lg font-semibold">Notebook</h2>
          <p className="text-sm text-muted">{filteredNotes.length} of {notes.length} notes</p>
        </div>
        <div className="flex items-center gap-1.5">
          <div className="relative">
            <Search className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" size={16} />
            <Input
              className="pl-9"
              onChange={(event) => { setQuery(event.target.value); resetPage(); }}
              placeholder="Search notes"
              value={query}
            />
          </div>
          <Button onClick={() => void handleAddNote()} icon={<Plus size={16} />}>New Note</Button>
        </div>
      </div>

      {/* Tag tabs */}
      <div className="flex flex-wrap items-center gap-1.5">
        <button
          onClick={() => { setActiveTag("all"); resetPage(); }}
          className={cn(
            "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
            activeTag === "all"
              ? "bg-accent text-accentForeground"
              : "bg-surface/50 text-muted hover:bg-surface hover:text-strong",
          )}
        >
          All
        </button>
        {tags.map((tag) => (
          <button
            key={tag.id}
            onClick={() => { setActiveTag(tag.name); resetPage(); }}
            className={cn(
              "rounded-md px-2.5 py-1 text-xs font-medium transition-colors",
              activeTag === tag.name
                ? "bg-accent text-accentForeground"
                : "bg-surface/50 text-muted hover:bg-surface hover:text-strong",
            )}
          >
            {tag.name}
          </button>
        ))}
      </div>

      {/* Note list */}
      <div className="min-h-0 flex-1 overflow-y-auto rounded-lg border border-border/60">
        <div className="sticky top-0 z-10 grid grid-cols-[1fr_auto_auto] items-center gap-2 border-b border-border/60 bg-panel/95 px-3 py-1.5 text-[11px] font-medium uppercase tracking-wider text-muted backdrop-blur">
          <span>Note</span>
          <span className="w-20 text-center">Tag</span>
          <span className="w-16" />
        </div>

        <div className="divide-y divide-border/40">
          {pageNotes.map((note, index) => {
            const isEditing = editingId === note.id;
            return (
              <div
                key={note.id}
                className={cn(
                  "transition-colors",
                  index % 2 === 1 ? "bg-surface/20" : "",
                  isEditing ? "bg-surface/40" : "hover:bg-surface/30",
                )}
              >
                {isEditing ? (
                  <div className="grid gap-2 px-3 py-2">
                    <Input
                      onChange={(e) => setEditName(e.target.value)}
                      placeholder="Note name (optional)"
                      value={editName}
                    />
                    <Textarea
                      className="min-h-[60px]"
                      onChange={(e) => setEditContent(e.target.value)}
                      placeholder="Content"
                      value={editContent}
                    />
                    <div className="flex items-center gap-2">
                      <Button onClick={() => void handleSaveEdit()} variant="primary" icon={<Check size={14} />} className="h-7 text-xs">Save</Button>
                      <Button onClick={cancelEdit} variant="ghost" icon={<X size={14} />} className="h-7 text-xs">Cancel</Button>
                    </div>
                  </div>
                ) : (
                  <div className="grid w-full grid-cols-[1fr_auto_auto] items-center gap-2 px-3 py-2">
                    <div className="min-w-0 truncate">
                      {note.name && <span className="font-medium text-strong">{note.name}: </span>}
                      <span className="text-sm text-content/80">{note.content}</span>
                    </div>
                    <Select
                      className="h-7 w-20 text-xs"
                      onChange={(e) => void handleChangeTag(note.id, e.target.value)}
                      value={note.tags[0] ?? ""}
                    >
                      {tags.map((tag) => (
                        <option key={tag.id} value={tag.name}>{tag.name}</option>
                      ))}
                    </Select>
                    <div className="flex w-16 items-center justify-end gap-1">
                      <Button
                        onClick={() => startEdit(note)}
                        variant="ghost"
                        className="h-6 min-h-6 px-1 text-xs text-muted/50 hover:text-strong"
                      >
                        Edit
                      </Button>
                      <Button
                        aria-label="Delete note"
                        onClick={() => void handleDeleteNote(note.id)}
                        variant="ghost"
                        icon={<Trash2 size={13} />}
                        className="h-6 min-h-6 w-6 px-0 text-muted/50 hover:text-red-500"
                      />
                    </div>
                  </div>
                )}
              </div>
            );
          })}
        </div>

        {pageNotes.length === 0 ? (
          <div className="px-3 py-6 text-center text-sm text-muted">
            {notes.length === 0 ? "No notes yet. Use the Note tool to save text." : "No notes match this filter."}
          </div>
        ) : null}

        {/* Pagination */}
        {totalPages > 1 ? (
          <div className="flex items-center justify-center gap-3 border-t border-border/40 py-2.5 text-sm">
            <Button
              disabled={safeCurrentPage <= 1}
              onClick={() => { setCurrentPage((p) => p - 1); setEditingId(null); }}
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
              onClick={() => { setCurrentPage((p) => p + 1); setEditingId(null); }}
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
