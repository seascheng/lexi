import { emit, listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { CornerDownLeft, Search, Trash2 } from "lucide-react";
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

  // Keep the backend's pending-note in sync so the tap's Enter can insert the
  // highlighted note without relying on the throttled webview key path.
  useEffect(() => {
    if (!isTauriRuntime()) return;
    const note = selectedIdx >= 0 ? filteredNotes[selectedIdx] : undefined;
    void invoke("set_pending_note", { text: note?.content ?? null });
  }, [filteredNotes, selectedIdx]);
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
      await invoke("set_popup_up", { visible: false });
    }
  }, []);

  /// Hapigo-style: type the note straight into the input the popup was
  /// summoned from. The backend reactivates that app (the caret survives as
  /// first responder) and inserts at the caret.
  const insertNoteContent = useCallback(async (note: NoteEntry) => {
    if (!isTauriRuntime()) return;
    try {
      await invoke("insert_at_focus", { text: note.content });
      if (!pinnedRef.current) {
        await getCurrentWindow().hide();
        await invoke("set_popup_up", { visible: false });
      }
    } catch (error) {
      // Panel stays up on failure — the user can still copy (⌘C) by hand.
      console.warn("insert_at_focus failed", error);
    }
  }, []);

  const copySelectedNote = useCallback(async () => {
    const note = selectedNote();
    if (!note) return;
    await copyNoteContent(note);
  }, [copyNoteContent, selectedNote]);

  const insertSelectedNote = useCallback(async () => {
    const note = selectedNote();
    if (!note) return;
    await insertNoteContent(note);
  }, [insertNoteContent, selectedNote]);

  useEffect(() => {
    void loadNotes();

    if (isTauriRuntime()) {
      const cleanup = listen("lexi://notes-changed", () => { void loadNotes(); });
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
      } else if (e.key === "Enter") {
        if (!selectedNote()) return;
        e.preventDefault();
        void insertSelectedNote();
      } else if (e.key === "Copy" || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "c")) {
        if (!selectedNote()) return;
        e.preventDefault();
        void copySelectedNote();
      }
    }

    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [insertSelectedNote, copySelectedNote, selectedNote]);

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
    await emit("lexi://notes-changed");
    await loadNotes();
  }

  if (notes.length === 0) {
    return <div className="px-3 py-4 text-sm text-muted">No notes yet.</div>;
  }

  return (
    <div className="flex min-h-0 flex-col gap-1.5 p-2">
      <div className="flex shrink-0 items-center rounded-lg border border-border bg-surface/60 p-1 transition-colors focus-within:border-accent/60">
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
                void insertNoteContent(note);
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
                "flex items-center gap-2 rounded px-2 py-1.5 outline-none transition-colors",
                selectedIdx === index
                  ? "bg-surface text-strong"
                  : "text-muted hover:bg-surfaceHover hover:text-strong",
              )}
              onClick={() => {
                setSelectedIdx(index);
                selectedRef.current = index;
              }}
              onDoubleClick={() => void insertNoteContent(note)}
              role="button"
              tabIndex={0}
            >
              <div className="min-w-0 flex-1 truncate">
                {note.name && (
                  <span className="font-medium">{note.name}: </span>
                )}
                <span className="text-sm">{note.content}</span>
              </div>
              <Button
                aria-label="Insert note at cursor"
                onClick={(e) => { e.stopPropagation(); void insertNoteContent(note); }}
                variant="ghost"
                icon={<CornerDownLeft size={13} />}
                className="h-6 min-h-6 w-6 shrink-0 px-0 text-muted hover:text-strong"
              />
              <Button
                aria-label="Delete note"
                onClick={(e) => { e.stopPropagation(); void removeNote(note.id); }}
                variant="ghost"
                icon={<Trash2 size={13} />}
                className="h-6 min-h-6 w-6 shrink-0 px-0 text-muted hover:text-danger"
              />
            </div>
          ))
        )}
      </div>
    </div>
  );
}
