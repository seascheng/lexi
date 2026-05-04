import { emit, listen } from "@tauri-apps/api/event";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Search, Trash2 } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { NoteEntry } from "../../types";
import { deleteNote, listNotes } from "../../lib/database";
import { copyText } from "../../lib/ai";
import { isTauriRuntime } from "../../lib/platform";
import type { PanelProps } from "../../lib/panelRegistry";
import { Button } from "../ui/Button";
import { cn } from "../../lib/cn";

function fuzzyMatch(text: string, query: string): boolean {
  const lower = text.toLowerCase();
  const q = query.toLowerCase();
  if (lower.includes(q)) return true;
  let qi = 0;
  for (let i = 0; i < lower.length && qi < q.length; i++) {
    if (lower[i] === q[qi]) qi++;
  }
  return qi === q.length;
}

export function NotesPanel({ isPinned }: PanelProps) {
  const [notes, setNotes] = useState<NoteEntry[]>([]);
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedIdx, setSelectedIdx] = useState(-1);
  const notesRef = useRef<NoteEntry[]>([]);
  const selectedRef = useRef(-1);
  const pinnedRef = useRef(isPinned ?? true);
  const searchRef = useRef<HTMLInputElement>(null);

  const filteredNotes = useMemo(() => {
    if (!searchQuery.trim()) return notes;
    const q = searchQuery.trim();
    return notes.filter((note) =>
      fuzzyMatch(note.name ?? "", q) || fuzzyMatch(note.content, q),
    );
  }, [notes, searchQuery]);

  useEffect(() => { notesRef.current = filteredNotes; }, [filteredNotes]);
  useEffect(() => { selectedRef.current = selectedIdx; }, [selectedIdx]);
  useEffect(() => { pinnedRef.current = isPinned ?? true; }, [isPinned]);

  // Reset selection when filter changes
  useEffect(() => {
    setSelectedIdx(-1);
    selectedRef.current = -1;
  }, [searchQuery]);

  const selectedNote = useCallback(() => {
    const idx = selectedRef.current;
    const note = notesRef.current[idx];
    return idx >= 0 ? note : undefined;
  }, []);

  const copyNoteContent = useCallback(async (note: NoteEntry) => {
    await copyText(note.content);
    if (!pinnedRef.current && isTauriRuntime()) {
      await getCurrentWindow().hide();
    }
  }, []);

  const copySelectedNote = useCallback(async () => {
    const note = selectedNote();
    if (!note) return;
    await copyNoteContent(note);
  }, [copyNoteContent, selectedNote]);

  useEffect(() => {
    void loadNotes();

    if (isTauriRuntime()) {
      const cleanup = listen("englist://notes-changed", () => { void loadNotes(); });
      return () => { void cleanup.then((unsub) => unsub()); };
    }
  }, []);

  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      const tag = (e.target as HTMLElement).tagName;
      const inInput = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
      if (inInput) return;

      const n = notesRef.current;
      if (n.length === 0) return;

      if (e.key === "ArrowDown") {
        e.preventDefault();
        setSelectedIdx((i) => {
          const next = Math.min(i + 1, n.length - 1);
          selectedRef.current = next;
          return next;
        });
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setSelectedIdx((i) => {
          const next = i < 0 ? 0 : Math.max(i - 1, 0);
          selectedRef.current = next;
          return next;
        });
      } else if (e.key === "Enter" || e.key === "Copy" || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "c")) {
        if (!selectedNote()) return;
        e.preventDefault();
        void copySelectedNote();
      }
    }

    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [copySelectedNote, selectedNote]);

  useEffect(() => {
    function onCopy(event: ClipboardEvent) {
      const selectedText = window.getSelection()?.toString();
      if (selectedText) return;

      const note = selectedNote();
      if (!note) return;

      event.preventDefault();
      event.clipboardData?.setData("text/plain", note.content);
      void copyNoteContent(note);
    }

    document.addEventListener("copy", onCopy, true);
    return () => document.removeEventListener("copy", onCopy, true);
  }, [copyNoteContent, selectedNote]);

  async function loadNotes() {
    setNotes(await listNotes());
    setSelectedIdx(-1);
    selectedRef.current = -1;
  }

  async function removeNote(id: number) {
    await deleteNote(id);
    await emit("englist://notes-changed");
    await loadNotes();
  }

  if (notes.length === 0) {
    return <div className="px-3 py-4 text-sm text-muted">No notes yet.</div>;
  }

  return (
    <div className="flex min-h-0 flex-col gap-1.5 p-2">
      <div className="flex shrink-0 items-center rounded-lg border border-strong/10 bg-input p-1">
        <Search size={13} className="ml-1.5 shrink-0 text-muted/60" />
        <input
          ref={searchRef}
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          onKeyDown={(e) => {
            const n = filteredNotes;
            if (n.length === 0) return;
            if (e.key === "ArrowDown") {
              e.preventDefault();
              setSelectedIdx((i) => {
                const next = Math.min(i + 1, n.length - 1);
                selectedRef.current = next;
                return next;
              });
            } else if (e.key === "ArrowUp") {
              e.preventDefault();
              setSelectedIdx((i) => {
                const next = i < 0 ? 0 : Math.max(i - 1, 0);
                selectedRef.current = next;
                return next;
              });
            } else if (e.key === "Enter") {
              const note = selectedIdx >= 0 ? filteredNotes[selectedIdx] : undefined;
              if (note) {
                e.preventDefault();
                void copyNoteContent(note);
              }
            }
          }}
          placeholder="Search notes..."
          className="min-w-0 flex-1 border-0 bg-transparent px-2 py-1.5 text-sm leading-5 text-strong outline-none placeholder:text-muted"
        />
      </div>
      <div className="flex min-h-0 flex-col overflow-y-auto">
        {filteredNotes.length === 0 ? (
          <div className="px-2 py-3 text-sm text-muted">No matching notes.</div>
        ) : (
          filteredNotes.map((note, index) => (
            <div
              key={note.id}
              className={cn(
                "flex items-center gap-2 rounded px-2 py-1.5 cursor-pointer outline-none transition-colors",
                selectedIdx === index
                  ? "bg-surface text-accent"
                  : "hover:bg-surfaceHover",
              )}
              onClick={() => {
                setSelectedIdx(index);
                selectedRef.current = index;
              }}
              onDoubleClick={() => void copyNoteContent(note)}
              role="button"
              tabIndex={0}
            >
              <div className="min-w-0 flex-1 truncate">
                {note.name && (
                  <span className="font-medium text-strong">{note.name}: </span>
                )}
                <span className="text-sm text-content">{note.content}</span>
              </div>
              <Button
                aria-label="Delete note"
                onClick={(e) => { e.stopPropagation(); void removeNote(note.id); }}
                variant="ghost"
                icon={<Trash2 size={13} />}
                className="h-6 min-h-6 w-6 shrink-0 px-0 text-muted/50 hover:text-danger"
              />
            </div>
          ))
        )}
      </div>
    </div>
  );
}
