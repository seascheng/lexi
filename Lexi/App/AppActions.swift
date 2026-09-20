import AppKit
import Foundation

struct ToolbarAction: Decodable {
    let id: String
    let title: String
    let icon: String
}

func defaultToolbarActions() -> [ToolbarAction] {
    [
        ToolbarAction(id: "translation", title: "Translate", icon: "languages"),
        ToolbarAction(id: "rewrite", title: "Rewrite", icon: "wand"),
        ToolbarAction(id: "speak", title: "Speak", icon: "volume"),
        ToolbarAction(id: "extract", title: "Extract", icon: "sparkles"),
    ]
}

extension SelectionToolbarApp {
    /// Fresh notes snapshot from the DB — the card Notes tab and the
    /// clipboard panel's category tabs both render from it.
    static func cardNotesPayload() -> CardNotesPayload {
        let rows = LexiStore.notes(limit: 50)
        return CardNotesPayload(
            notes: rows.map {
                CardNotesPayload.Note(
                    id: $0.id, name: $0.name, category: $0.categoryName,
                    content: $0.content, sort: $0.sortOrder)
            },
            categories: LexiStore.noteCategories().map(\.name)
        )
    }

    /// The clipboard shortcut's local path: refresh the notes snapshot from
    /// the shared DB (the category tabs read it) and present the panel.
    /// Panels are independent surfaces — macOS focus handling retires the
    /// others.
    func showClipboardPanel() {
        pushNotesToClipboardPanel(Self.cardNotesPayload())
        clipboardController.show()
    }

    /// The clipboard panel renders the same notes feed the card's notes
    /// tab does — push the snapshot to it too, or writes made THROUGH the
    /// panel (rename/move/create) never reflect in its own rows.
    func pushNotesToClipboardPanel(_ payload: CardNotesPayload) {
        clipboardController.updateNotes(
            notes: payload.notes.map {
                ClipboardNote(
                    id: $0.id ?? 0, name: $0.name, content: $0.content,
                    category: $0.category, sort: $0.sort)
            },
            categories: payload.categories ?? [])
    }

    @objc func runToolbarAction(_ sender: NSButton) {
        guard let action = sender.identifier?.rawValue, !selectedText.isEmpty else {
            return
        }
        if LexiTools.isTool(id: action) {
            LexiTools.run(id: action, text: selectedText)
        } else {
            runFeatureLocally(featureId: action, text: selectedText)
        }
        hidePanel()
    }

    /// Local handling for every former Rust round-trip action. Rust is
    /// gone: DB writes, tool execution, and quit all happen here.
    func handleAction(action: String, text: String) {
        switch action {
        case "quit-lexi":
            NSApp.terminate(nil)
        case "save-vocab":
            saveVocabAction(text)
        case "note-delete":
            if let id = Int64(text.trimmingCharacters(in: .whitespaces)) {
                LexiStore.deleteNote(id: id)
                reloadCardNotes()
            }
        case "note-rename":
            if let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = value["id"] as? Int64,
               let name = value["name"] as? String {
                LexiStore.updateNoteName(id: id, name: name)
                reloadCardNotes()
            }
        case "note-tag-create":
            LexiStore.createNoteCategory(name: text)
            reloadCardNotes()
        case "note-tag":
            // Move a note to a category ("id|Category Name").
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let id = Int64(parts.first ?? ""), let name = parts.last, !name.isEmpty {
                LexiStore.setNoteCategory(
                    id: id,
                    categoryId: LexiStore.noteCategoryIdOrCreate(named: String(name))
                )
                reloadCardNotes()
            }
        case "note-create":
            if let data = text.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                LexiStore.insertNote(
                    name: value["name"] ?? "", content: value["content"] ?? "",
                    category: value["tag"] ?? ""
                )
                reloadCardNotes()
            }
        case "note-tag-rename":
            // "oldName|newName"
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let old = parts.first, let new = parts.last, !new.isEmpty,
               let id = LexiStore.noteCategoryId(named: String(old)) {
                LexiStore.renameNoteCategory(id: id, name: String(new))
                reloadCardNotes()
            }
        case "note-tag-delete":
            if let id = LexiStore.noteCategoryId(named: text) {
                LexiStore.deleteNoteCategory(id: id)
                reloadCardNotes()
            }
        case "note-tag-color":
            // "name|#RRGGBB" (empty hex resets to the hash color)
            let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            if let name = parts.first {
                LexiStore.setNoteCategoryColor(named: String(name), hex: String(parts.last ?? ""))
                reloadCardNotes()
            }
        case "note-tag-reorder":
            if let data = text.data(using: .utf8),
               let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
                LexiStore.reorderNoteCategories(byNames: names)
                reloadCardNotes()
            }
        case "note-reorder":
            // Comma-joined note ids — the clipboard panel's row drag.
            let ids = text.split(separator: ",").compactMap { Int64($0) }
            if !ids.isEmpty {
                LexiStore.reorderNotes(ids: ids)
                reloadCardNotes()
            }
        case "note-insert":
            ClipboardPaster.pasteString(text, previousApp: sourceApp)
        case "handoff":
            LexiTools.handoff(text: text)
        default:
            FileLog.write("ACTION dropped \(action) (no local handler)")
        }
    }

    /// Save button on the card: persist the run's translation JSON with the
    /// entry type the user picked (Rust save_vocab_action parity).
    func saveVocabAction(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let word = payload["word"] as? String,
              !word.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }
        let field = { (key: String) -> String in payload[key] as? String ?? "" }
        let entryType = field("entryType").isEmpty ? "word" : field("entryType")
        LexiStore.insertWord(
            word: word, translation: field("translation"), pos: field("pos"),
            definition: field("definition"), example: field("example"),
            entryType: entryType, sourceText: field("sourceText")
        )
    }

    func reloadCardNotes() {
        let payload = Self.cardNotesPayload()
        handleCardNotes(payload)
        pushNotesToClipboardPanel(payload)
    }
}
