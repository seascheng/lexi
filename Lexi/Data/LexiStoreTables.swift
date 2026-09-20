import Foundation
import SQLite3

/// One `ai_features` row — everything a local run needs.
struct LexiAIFeature {
    let id: String
    let name: String
    let promptTemplate: String
    let outputMode: String
    let targetLanguage: String
    let icon: String
    let autoSave: Bool
    let thinking: Bool
}

extension LexiStore {
    static func aiFeature(id: String) -> LexiAIFeature? {
        var feature: LexiAIFeature?
        query(
            "SELECT name, prompt_template, output_mode, IFNULL(target_language,''), IFNULL(icon,'wand'), auto_save_to_vocabulary, IFNULL(thinking,0) FROM ai_features WHERE id = ?1 LIMIT 1;",
            { bindText($0, 1, id) }
        ) { stmt in
            feature = LexiAIFeature(
                id: id,
                name: columnText(stmt, 0),
                promptTemplate: columnText(stmt, 1),
                outputMode: columnText(stmt, 2),
                targetLanguage: columnText(stmt, 3),
                icon: columnText(stmt, 4),
                autoSave: sqlite3_column_int64(stmt, 5) == 1,
                thinking: sqlite3_column_int64(stmt, 6) == 1
            )
        }
        return feature
    }


    /// A toolbar tool's `config` object from the `toolbar_tools` JSON blob
    /// (string values only — that is all the current schema stores).
    static func toolbarToolConfig(id: String) -> [String: String] {
        guard let raw = setting("toolbar_tools"),
              let data = raw.data(using: .utf8),
              let tools = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [:] }
        guard let tool = tools.first(where: { $0["id"] as? String == id }),
              let config = tool["config"] as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in config {
            result[key] = String(describing: value)
        }
        return result
    }

    /// Set one field of a tool's config (read-modify-write of the blob).
    static func setToolConfigField(id: String, field: String, value: String) {
        guard let raw = setting("toolbar_tools"),
              let data = raw.data(using: .utf8),
              var tools = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let index = tools.firstIndex(where: { ($0["id"] as? String) == id })
        else { return }
        var config = tools[index]["config"] as? [String: String] ?? [:]
        config[field] = value
        tools[index]["config"] = config
        if let out = try? JSONSerialization.data(withJSONObject: tools),
           let raw = String(data: out, encoding: .utf8) {
            setSetting("toolbar_tools", raw)
        }
    }

    /// Vocabulary auto-save.
    static func insertWord(
        word: String, translation: String, pos: String,
        definition: String, example: String,
        entryType: String, sourceText: String
    ) {
        run("INSERT INTO words (word, translation, pos, definition, example, status, entry_type, source_text) VALUES (?1, ?2, ?3, ?4, ?5, 'new', ?6, ?7);") {
            bindText($0, 1, word)
            bindText($0, 2, translation)
            bindText($0, 3, pos)
            bindText($0, 4, definition)
            bindText($0, 5, example)
            bindText($0, 6, entryType)
            bindText($0, 7, sourceText)
        }
    }
}

struct LexiWord: Identifiable, Hashable {
    let id: Int64
    let word: String
    let translation: String
    let pos: String
    let definition: String
    let example: String
    let status: String
    let entryType: String
    let note: String
    let reviewCount: Int
    let nextReview: String?
    let createdAt: String
}

extension LexiStore {
    /// Paged, searched word list. Empty search + nil status = whole table.
    static func words(search: String, status: String?, offset: Int, limit: Int) -> [LexiWord] {
        var clauses: [String] = []
        var bindings: [String] = []
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            clauses.append("(word LIKE ?1 OR translation LIKE ?1)")
            bindings.append("%\(trimmed)%")
        }
        if let status, !status.isEmpty {
            clauses.append("status = ?\(bindings.count + 1)")
            bindings.append(status)
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = "SELECT id, word, translation, IFNULL(pos,''), IFNULL(definition,''), IFNULL(example,''), status, IFNULL(entry_type,'word'), IFNULL(note,''), review_count, strftime('%Y-%m-%d', next_review), strftime('%Y-%m-%d', created_at) FROM words \(whereSQL) ORDER BY created_at DESC, id DESC LIMIT ?\(bindings.count + 1) OFFSET ?\(bindings.count + 2);"

        var rows: [LexiWord] = []
        query(sql, { stmt in
            for (index, value) in bindings.enumerated() {
                bindText(stmt, Int32(index + 1), value)
            }
            bindInt(stmt, Int32(bindings.count + 1), Int32(limit))
            bindInt(stmt, Int32(bindings.count + 2), Int32(offset))
        }) { stmt in
            rows.append(LexiWord(
                id: sqlite3_column_int64(stmt, 0),
                word: columnText(stmt, 1), translation: columnText(stmt, 2), pos: columnText(stmt, 3),
                definition: columnText(stmt, 4), example: columnText(stmt, 5), status: columnText(stmt, 6),
                entryType: columnText(stmt, 7), note: columnText(stmt, 8),
                reviewCount: Int(sqlite3_column_int(stmt, 9)),
                nextReview: columnOptionalText(stmt, 10),
                createdAt: columnOptionalText(stmt, 11) ?? ""
            ))
        }
        return rows
    }

    /// Row counts per status — the filter chips and the review badge.
    static func wordCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        query("SELECT status, COUNT(*) FROM words GROUP BY status;") { stmt in
            counts[columnText(stmt, 0)] = Int(sqlite3_column_int(stmt, 1))
        }
        return counts
    }

    /// Words due for review (the card Review tab's queue rule).
    static func nextReviewWord() -> LexiWord? {
        var word: LexiWord?
        query(
            "SELECT id, word, translation, IFNULL(pos,''), IFNULL(definition,''), IFNULL(example,''), status, IFNULL(entry_type,'word'), IFNULL(note,''), review_count, strftime('%Y-%m-%d', next_review) FROM words WHERE status != 'mastered' AND (next_review IS NULL OR next_review <= date('now')) ORDER BY RANDOM() LIMIT 1;"
        ) { stmt in
            word = LexiWord(
                id: sqlite3_column_int64(stmt, 0),
                word: columnText(stmt, 1), translation: columnText(stmt, 2), pos: columnText(stmt, 3),
                definition: columnText(stmt, 4), example: columnText(stmt, 5), status: columnText(stmt, 6),
                entryType: columnText(stmt, 7), note: columnText(stmt, 8),
                reviewCount: Int(sqlite3_column_int(stmt, 9)),
                nextReview: columnOptionalText(stmt, 10),
                createdAt: ""
            )
        }
        return word
    }

    /// How many words the review queue holds right now.
    static func dueReviewCount() -> Int {
        var count = 0
        query("SELECT COUNT(*) FROM words WHERE status != 'mastered' AND (next_review IS NULL OR next_review <= date('now'));") { stmt in
            count = Int(sqlite3_column_int(stmt, 0))
        }
        return count
    }

    /// Apply an SM-2 schedule and persist it (idempotent per word state).
    static func applyReviewGrade(id: Int64, rating: String) {
        var current: (count: Int, ease: Double, interval: Int)?
        query(
            "SELECT review_count, ease_factor, interval FROM words WHERE id = ?1;",
            { bindInt64($0, 1, id) }
        ) { stmt in
            current = (
                Int(sqlite3_column_int(stmt, 0)),
                sqlite3_column_double(stmt, 1),
                Int(sqlite3_column_int(stmt, 2))
            )
        }
        guard let state = current else { return }
        let next = SM2.schedule(rating: rating, ease: state.ease, interval: state.interval, count: state.count)
        run("UPDATE words SET status = ?1, review_count = ?2, next_review = ?3, ease_factor = ?4, interval = ?5 WHERE id = ?6;") {
            bindText($0, 1, next.status)
            bindInt($0, 2, Int32(next.reviewCount))
            bindText($0, 3, next.nextReview)
            sqlite3_bind_double($0, 4, next.easeFactor)
            bindInt($0, 5, Int32(next.interval))
            bindInt64($0, 6, id)
        }
    }

    static func deleteWord(id: Int64) {
        run("DELETE FROM words WHERE id = ?1;", { bindInt64($0, 1, id) })
    }

    /// The expanded row's status switcher.
    static func setWordStatus(id: Int64, status: String) {
        run("UPDATE words SET status = ?1 WHERE id = ?2;") {
            bindText($0, 1, status)
            bindInt64($0, 2, id)
        }
    }
}

/// One notes-table row with its category.
struct LexiNote: Identifiable, Hashable {
    let id: Int64
    let name: String
    let content: String
    var categoryId: Int64?
    var categoryName: String?
    /// Manual order within the category (drag-reorder); 0 = never moved
    /// (falls back to recency).
    var sortOrder: Int = 0
}

/// One note_categories row with its note count.
struct LexiNoteCategory: Identifiable, Hashable {
    let id: Int64
    let name: String
    let count: Int
    /// Custom chip color (hex string; empty = hash color).
    let color: String
}

/// One ai_features row (full editor surface).
struct LexiFeatureRow: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var promptTemplate: String
    var outputMode: String
    var enabled: Bool
    var sortOrder: Int
    var autoSave: Bool
    var targetLanguage: String
    var icon: String
    var isBuiltin: Bool
    var thinking: Bool
}

extension LexiStore {
    /// Latest notes with their category (the card Notes tab's query,
    /// unpagified for the pane's 200-row window).
    static func notes(limit: Int = 200) -> [LexiNote] {
        var rows: [LexiNote] = []
        query(
            """
            SELECT n.id, IFNULL(n.name,''), n.content, n.category_id, IFNULL(c.name,''), IFNULL(n.sort_order, 0)
            FROM notes n LEFT JOIN note_categories c ON c.id = n.category_id
            ORDER BY n.created_at DESC, n.id DESC LIMIT ?1;
            """,
            { bindInt($0, 1, Int32(limit)) }
        ) { stmt in
            let categoryName = columnText(stmt, 4)
            rows.append(LexiNote(
                id: sqlite3_column_int64(stmt, 0),
                name: columnText(stmt, 1),
                content: columnText(stmt, 2),
                categoryId: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3),
                categoryName: categoryName.isEmpty ? nil : categoryName,
                sortOrder: Int(sqlite3_column_int64(stmt, 5))
            ))
        }
        return rows
    }

    /// Manual note order inside a category (drag-reorder in the clipboard
    /// panel): index order over the given ids.
    static func reorderNotes(ids: [Int64]) {
        for (index, id) in ids.enumerated() {
            run("UPDATE notes SET sort_order = ?1 WHERE id = ?2;") {
                bindInt($0, 1, Int32(index))
                bindInt64($0, 2, id)
            }
        }
    }

    static func deleteNote(id: Int64) {
        run("DELETE FROM notes WHERE id = ?1;", { bindInt64($0, 1, id) })
    }

    // MARK: - AI features

    static func features() -> [LexiFeatureRow] {
        var rows: [LexiFeatureRow] = []
        query(
            "SELECT id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, IFNULL(target_language,''), icon, is_builtin, thinking FROM ai_features ORDER BY sort_order, created_at;"
        ) { stmt in
            rows.append(LexiFeatureRow(
                id: columnText(stmt, 0), name: columnText(stmt, 1), kind: columnText(stmt, 2),
                promptTemplate: columnText(stmt, 3), outputMode: columnText(stmt, 4),
                enabled: sqlite3_column_int64(stmt, 5) == 1,
                sortOrder: Int(sqlite3_column_int(stmt, 6)),
                autoSave: sqlite3_column_int64(stmt, 7) == 1,
                targetLanguage: columnText(stmt, 8), icon: columnText(stmt, 9),
                isBuiltin: sqlite3_column_int64(stmt, 10) == 1,
                thinking: sqlite3_column_int64(stmt, 11) == 1
            ))
        }
        return rows
    }

    /// Insert or update one feature row.
    static func saveFeature(_ row: LexiFeatureRow) {
        run("""
            INSERT INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, icon, is_builtin, thinking, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12, datetime('now')) ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, prompt_template=excluded.prompt_template, output_mode=excluded.output_mode, enabled=excluded.enabled, sort_order=excluded.sort_order, auto_save_to_vocabulary=excluded.auto_save_to_vocabulary, target_language=excluded.target_language, icon=excluded.icon, thinking=excluded.thinking, updated_at=datetime('now');
            """) {
            bindText($0, 1, row.id)
            bindText($0, 2, row.name)
            bindText($0, 3, row.kind)
            bindText($0, 4, row.promptTemplate)
            bindText($0, 5, row.outputMode)
            bindInt($0, 6, row.enabled ? 1 : 0)
            bindInt($0, 7, Int32(row.sortOrder))
            bindInt($0, 8, row.autoSave ? 1 : 0)
            bindText($0, 9, row.targetLanguage)
            bindText($0, 10, row.icon)
            bindInt($0, 11, row.isBuiltin ? 1 : 0)
            bindInt($0, 12, row.thinking ? 1 : 0)
        }
    }

    static func deleteFeature(id: String) {
        run("DELETE FROM ai_features WHERE id = ?1 AND is_builtin = 0;", { bindText($0, 1, id) })
    }
}

extension LexiStore {
    /// The Note tool's write: a note row filed under one category
    /// (created on demand — "Note" is the tool's default bucket).
    static func insertNote(content: String, category: String = "Note") {
        guard run("INSERT INTO notes (name, content, created_at) VALUES (NULL, ?1, strftime('%Y-%m-%d %H:%M:%S','now'));", {
            bindText($0, 1, content)
        }) else { return }
        fileJustInsertedNote(under: category)
    }

    /// File the note inserted on this connection under one category
    /// (created on demand; an empty name leaves the note uncategorized)
    /// and seat it at the TOP of that category's manual order.
    private static func fileJustInsertedNote(under category: String) {
        let id = sqlite3_last_insert_rowid(open())
        let trimmed = category.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            setNoteCategory(id: id, categoryId: noteCategoryIdOrCreate(named: trimmed))
        }
        run("""
            UPDATE notes SET sort_order =
                (SELECT IFNULL(MIN(n.sort_order), 0) - 1 FROM notes n WHERE n.category_id = notes.category_id)
            WHERE id = ?1;
            """, { bindInt64($0, 1, id) })
    }


    /// Card notes-tab rename.
    static func updateNoteName(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        run("UPDATE notes SET name = ?1 WHERE id = ?2;") {
            bindText($0, 1, trimmed)
            bindInt64($0, 2, id)
        }
    }

    /// Notebook detail edit: replace the note body.
    static func updateNoteContent(id: Int64, content: String) {
        run("UPDATE notes SET content = ?1 WHERE id = ?2;") {
            bindText($0, 1, content)
            bindInt64($0, 2, id)
        }
    }

    /// Set the note's category; nil clears it.
    static func setNoteCategory(id: Int64, categoryId: Int64?) {
        run("UPDATE notes SET category_id = ?1 WHERE id = ?2;") {
            if let categoryId {
                bindInt64($0, 1, categoryId)
            } else {
                sqlite3_bind_null($0, 1)
            }
            bindInt64($0, 2, id)
        }
    }

    /// Categories with live note counts, management order.
    static func noteCategories() -> [LexiNoteCategory] {
        var rows: [LexiNoteCategory] = []
        query("""
            SELECT c.id, c.name, (SELECT COUNT(*) FROM notes n WHERE n.category_id = c.id),
                   IFNULL(c.color, '')
            FROM note_categories c ORDER BY c.sort_order, c.id;
            """) { stmt in
            rows.append(LexiNoteCategory(
                id: sqlite3_column_int64(stmt, 0),
                name: columnText(stmt, 1),
                count: Int(sqlite3_column_int64(stmt, 2)),
                color: columnText(stmt, 3)
            ))
        }
        return rows
    }

    /// Category names are unique; duplicates are silently dropped.
    static func createNoteCategory(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run("""
            INSERT OR IGNORE INTO note_categories (name, sort_order)
            VALUES (?1, (SELECT IFNULL(MAX(sort_order), 0) + 1 FROM note_categories));
            """, { bindText($0, 1, trimmed) })
    }

    static func renameNoteCategory(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        run("UPDATE OR IGNORE note_categories SET name = ?1 WHERE id = ?2;") {
            bindText($0, 1, trimmed)
            bindInt64($0, 2, id)
        }
    }

    /// Removing a category removes every note filed under it.
    static func deleteNoteCategory(id: Int64) {
        guard let db = open() else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        run("DELETE FROM notes WHERE category_id = ?1;", { bindInt64($0, 1, id) })
        run("DELETE FROM note_categories WHERE id = ?1;", { bindInt64($0, 1, id) })
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Clipboard panel's "移动到分类": save a clip as a note in a category
    /// (the panel deletes its own clip afterwards).
    static func insertNote(name: String, content: String, category: String) {
        guard run("INSERT INTO notes (name, content) VALUES (?1, ?2);", {
            bindText($0, 1, name)
            bindText($0, 2, content)
        }) else { return }
        fileJustInsertedNote(under: category)
    }

    /// Category id for a name, creating the row when missing.
    static func noteCategoryIdOrCreate(named name: String) -> Int64? {
        var existing: Int64?
        query("SELECT id FROM note_categories WHERE name = ?1;", { bindText($0, 1, name) }) { stmt in
            existing = sqlite3_column_int64(stmt, 0)
        }
        if let existing { return existing }

        run("""
            INSERT OR IGNORE INTO note_categories (name, sort_order) VALUES (?1, (SELECT IFNULL(MAX(sort_order), 0) + 1 FROM note_categories));
            """, { bindText($0, 1, name) })
        var created: Int64?
        query("SELECT id FROM note_categories WHERE name = ?1;", { bindText($0, 1, name) }) { stmt in
            created = sqlite3_column_int64(stmt, 0)
        }
        return created
    }

    /// Clipboard panel's drag-to-reorder: each category name gets its
    /// chip-row index as sort_order.
    static func reorderNoteCategories(byNames names: [String]) {
        for (index, name) in names.enumerated() {
            run("UPDATE note_categories SET sort_order = ?1 WHERE name = ?2;") {
                bindInt($0, 1, Int32(index))
                bindText($0, 2, name)
            }
        }
    }

    /// Category id for a name, nil when the category does not exist.
    static func noteCategoryId(named name: String) -> Int64? {
        var existing: Int64?
        query("SELECT id FROM note_categories WHERE name = ?1;", { bindText($0, 1, name) }) { stmt in
            existing = sqlite3_column_int64(stmt, 0)
        }
        return existing
    }

    /// Custom chip color (hex string) — nil falls back to the hash color.
    static func noteCategoryColor(named name: String) -> String? {
        var existing: String?
        query("SELECT IFNULL(color, '') FROM note_categories WHERE name = ?1;", { bindText($0, 1, name) }) { stmt in
            let raw = columnText(stmt, 0)
            if !raw.isEmpty { existing = raw }
        }
        return existing
    }

    /// Chip color picker: store the hex ("" clears back to the hash color).
    static func setNoteCategoryColor(named name: String, hex: String) {
        run("UPDATE note_categories SET color = ?1 WHERE name = ?2;") {
            bindText($0, 1, hex)
            bindText($0, 2, name)
        }
    }
}

/// One entry of the shared action registry (`toolbar_tools` blob): the
/// toolbar scope and the card's Actions-tab scope each read their columns.
struct LexiToolEntry: Codable, Identifiable, Hashable {
    var id: String
    // The blob historically has no name for tools — display falls back to id.
    var name: String?
    var enabled: Bool
    var sortOrder: Int
    var panelEnabled: Bool
    var panelSortOrder: Int
    var icon: String
    var config: [String: String]

    var displayName: String { (name?.isEmpty == false) ? name! : id }
}

extension LexiStore {
    /// The shared action registry (`toolbar_tools` JSON blob in settings).
    static func toolbarTools() -> [LexiToolEntry] {
        guard let raw = setting("toolbar_tools"),
              let data = raw.data(using: .utf8),
              let rows = try? JSONDecoder().decode([LexiToolEntry].self, from: data)
        else { return [] }
        return rows
    }

    static func saveToolbarTools(_ entries: [LexiToolEntry]) {
        guard let data = try? JSONEncoder().encode(entries),
              let raw = String(data: data, encoding: .utf8) else { return }
        setSetting("toolbar_tools", raw)
    }

    /// JSON string-array setting → [String]; malformed/absent reads empty.
    /// The one codec for every list-shaped setting in the KV store.
    static func stringArraySetting(_ key: String) -> [String] {
        guard let raw = setting(key),
              let ids = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return [] }
        return ids
    }

    static func saveStringArray(_ value: [String], for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        setSetting(key, String(data: data, encoding: .utf8) ?? "[]")
    }

    /// Launcher tag lists (known tags / order / disabled) — the launcher's
    /// config panes and folder grid share these keys.
    static func tagList(_ key: String) -> [String] {
        stringArraySetting(key)
    }

    static func saveTagList(_ value: [String], for key: String) {
        saveStringArray(value, for: key)
    }

    /// The single source of truth for toolbar button order: ids (built-in
    /// tools and AI features interleaved) in bar order. Both the live bar
    /// and the Toolbar config pane render from this list.
    static func toolbarOrder() -> [String] {
        stringArraySetting("toolbarOrder")
    }

    static func saveToolbarOrder(_ ids: [String]) {
        saveStringArray(ids, for: "toolbarOrder")
    }

    /// App bundle ids where the selection toolbar stays hidden. Absent or
    /// malformed setting defaults to Finder-only; a saved empty list stays
    /// empty (deliberate "exclude nothing").
    static func excludedToolbarApps() -> [String] {
        guard let raw = setting("excludedToolbarApps"),
              let list = try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
        else { return ["com.apple.finder"] }
        return list
    }

    static func saveExcludedToolbarApps(_ list: [String]) {
        saveStringArray(list, for: "excludedToolbarApps")
    }

}
