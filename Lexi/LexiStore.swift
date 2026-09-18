import Foundation
import SQLite3

/// Access to the main Lexi database (the tauri app-data store). Values are
/// plain TEXT key/value rows in `settings`, shared today with the React
/// webview — every statement runs with a busy timeout so concurrent writers
/// from either side simply wait instead of failing.

/// `SQLITE_TRANSIENT` is a C macro, invisible to Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
enum LexiStore {
    /// `com.lexi.app` is the tauri identifier; the native helper is a
    /// different bundle, so the path is spelled out rather than derived
    /// from Bundle.main.
    static var databasePath: String {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first
        return support?.appendingPathComponent("com.lexi.app/lexi.db").path ?? ""
    }

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 2_000)
        return db
    }

    /// Settings table row read. Returns nil when the key is absent.
    static func setting(_ key: String) -> String? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM settings WHERE key = ?1 LIMIT 1;", -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }

    /// Upsert one settings row.
    static func setSetting(_ key: String, _ value: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    static func settingBool(_ key: String, default fallback: Bool) -> Bool {
        switch setting(key) {
        case "true", "1": return true
        case "false", "0": return false
        default: return fallback
        }
    }

    static func settingInt(_ key: String, in range: ClosedRange<Int>, default fallback: Int) -> Int {
        guard let raw = setting(key), let parsed = Int(raw) else { return fallback }
        return range.contains(parsed) ? parsed : fallback
    }
}

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
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT name, prompt_template, output_mode, IFNULL(target_language,''), IFNULL(icon,'wand'), auto_save_to_vocabulary, IFNULL(thinking,0) FROM ai_features WHERE id = ?1 LIMIT 1;",
            -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func column(_ index: Int32) -> String {
            guard let text = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: text)
        }
        return LexiAIFeature(
            id: id,
            name: column(0),
            promptTemplate: column(1),
            outputMode: column(2),
            targetLanguage: column(3),
            icon: column(4),
            autoSave: sqlite3_column_int64(statement, 5) == 1,
            thinking: sqlite3_column_int64(statement, 6) == 1
        )
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

    /// Vocabulary auto-save — parity with the Rust pipeline's INSERT.
    static func insertWord(
        word: String, translation: String, pos: String,
        definition: String, example: String,
        entryType: String, sourceText: String
    ) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO words (word, translation, pos, definition, example, status, entry_type, source_text) VALUES (?1, ?2, ?3, ?4, ?5, 'new', ?6, ?7);",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, word, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, translation, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, pos, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, definition, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, example, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 6, entryType, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 7, sourceText, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
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
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }

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
        let sql = "SELECT id, word, translation, IFNULL(pos,''), IFNULL(definition,''), IFNULL(example,''), status, IFNULL(entry_type,'word'), IFNULL(note,''), review_count, strftime('%Y-%m-%d', next_review), strftime('%Y-%m-%d', created_at) FROM words \(whereSQL) ORDER BY created_at DESC, id DESC LIMIT \(limit) OFFSET \(offset);"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }

        var rows: [LexiWord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let cString = sqlite3_column_text(statement, i) else { return "" }
                return String(cString: cString)
            }
            func optionalText(_ i: Int32) -> String? {
                sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : text(i)
            }
            rows.append(LexiWord(
                id: sqlite3_column_int64(statement, 0),
                word: text(1), translation: text(2), pos: text(3),
                definition: text(4), example: text(5), status: text(6),
                entryType: text(7), note: text(8),
                reviewCount: Int(sqlite3_column_int(statement, 9)),
                nextReview: optionalText(10),
                createdAt: optionalText(11) ?? ""
            ))
        }
        return rows
    }

    /// Row counts per status — the filter chips and the review badge.
    static func wordCounts() -> [String: Int] {
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT status, COUNT(*) FROM words GROUP BY status;", -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            counts[String(cString: cString)] = Int(sqlite3_column_int(statement, 1))
        }
        return counts
    }

    /// Words due for review (the card Review tab's queue rule).
    static func nextReviewWord() -> LexiWord? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, word, translation, IFNULL(pos,''), IFNULL(definition,''), IFNULL(example,''), status, IFNULL(entry_type,'word'), IFNULL(note,''), review_count, strftime('%Y-%m-%d', next_review) FROM words WHERE status != 'mastered' AND (next_review IS NULL OR next_review <= date('now')) ORDER BY RANDOM() LIMIT 1;",
            -1, &statement, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        func text(_ i: Int32) -> String {
            guard let cString = sqlite3_column_text(statement, i) else { return "" }
            return String(cString: cString)
        }
        let nextReview: String? = sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : text(10)
        return LexiWord(
            id: sqlite3_column_int64(statement, 0),
            word: text(1), translation: text(2), pos: text(3),
            definition: text(4), example: text(5), status: text(6),
            entryType: text(7), note: text(8),
            reviewCount: Int(sqlite3_column_int(statement, 9)),
            nextReview: nextReview,
            createdAt: ""
        )
    }

    /// How many words the review queue holds right now.
    static func dueReviewCount() -> Int {
        guard let db = open() else { return 0 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM words WHERE status != 'mastered' AND (next_review IS NULL OR next_review <= date('now'));",
            -1, &statement, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Apply an SM-2 schedule and persist it (idempotent per word state).
    static func applyReviewGrade(id: Int64, rating: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT review_count, ease_factor, interval FROM words WHERE id = ?1;", -1, &statement, nil
 ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return }
        let count = Int(sqlite3_column_int(statement, 0))
        let ease = sqlite3_column_double(statement, 1)
        let interval = Int(sqlite3_column_int(statement, 2))

        let next = SM2.schedule(rating: rating, ease: ease, interval: interval, count: count)
        var update: OpaquePointer?
        let sql = "UPDATE words SET status = ?, review_count = ?, next_review = ?, ease_factor = ?, interval = ? WHERE id = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &update, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(update) }
        sqlite3_bind_text(update, 1, next.status, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(update, 2, Int32(next.reviewCount))
        sqlite3_bind_text(update, 3, next.nextReview, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(update, 4, next.easeFactor)
        sqlite3_bind_int(update, 5, Int32(next.interval))
        sqlite3_bind_int64(update, 6, id)
        sqlite3_step(update)
    }

    static func deleteWord(id: Int64) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM words WHERE id = ?1;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_step(statement)
    }

    /// The expanded row's status switcher (React updateWordStatus).
    static func setWordStatus(id: Int64, status: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE words SET status = ?1 WHERE id = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, status, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }
}


/// One notes-table row with its category.
struct LexiNote: Identifiable, Hashable {
    let id: Int64
    let name: String
    let content: String
    var categoryId: Int64?
    var categoryName: String?
}

/// One note_categories row with its note count.
struct LexiNoteCategory: Identifiable, Hashable {
    let id: Int64
    let name: String
    let count: Int
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
    var speechEnabled: Bool
}

extension LexiStore {
    /// Latest notes with their tags (the card Notes tab's query, unpagified
    /// for the pane's 200-row window).
    static func notes(limit: Int = 200) -> [LexiNote] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT n.id, IFNULL(n.name,''), n.content, n.category_id, IFNULL(c.name, '')
            FROM notes n LEFT JOIN note_categories c ON c.id = n.category_id
            ORDER BY n.created_at DESC, n.id DESC LIMIT \(limit);
            """,
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [LexiNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let cString = sqlite3_column_text(statement, i) else { return "" }
                return String(cString: cString)
            }
            let categoryId: Int64? = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 3)
            let categoryName = text(4)
            rows.append(LexiNote(
                id: sqlite3_column_int64(statement, 0), name: text(1), content: text(2),
                categoryId: categoryId, categoryName: categoryName.isEmpty ? nil : categoryName
            ))
        }
        return rows
    }

    static func deleteNote(id: Int64) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM notes WHERE id = ?1;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_step(statement)
    }

    // MARK: - AI features

    static func features() -> [LexiFeatureRow] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, IFNULL(target_language,''), icon, is_builtin, thinking, speech_enabled FROM ai_features ORDER BY sort_order, created_at;",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [LexiFeatureRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let cString = sqlite3_column_text(statement, i) else { return "" }
                return String(cString: cString)
            }
            rows.append(LexiFeatureRow(
                id: text(0), name: text(1), kind: text(2), promptTemplate: text(3),
                outputMode: text(4), enabled: sqlite3_column_int64(statement, 5) == 1,
                sortOrder: Int(sqlite3_column_int(statement, 6)),
                autoSave: sqlite3_column_int64(statement, 7) == 1,
                targetLanguage: text(8), icon: text(9),
                isBuiltin: sqlite3_column_int64(statement, 10) == 1,
                thinking: sqlite3_column_int64(statement, 11) == 1,
                speechEnabled: sqlite3_column_int64(statement, 12) == 1
            ))
        }
        return rows
    }

    /// Insert or update one feature row.
    static func saveFeature(_ row: LexiFeatureRow) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, icon, is_builtin, thinking, speech_enabled, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13, datetime('now')) ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, prompt_template=excluded.prompt_template, output_mode=excluded.output_mode, enabled=excluded.enabled, sort_order=excluded.sort_order, auto_save_to_vocabulary=excluded.auto_save_to_vocabulary, target_language=excluded.target_language, icon=excluded.icon, thinking=excluded.thinking, speech_enabled=excluded.speech_enabled, updated_at=datetime('now');",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, row.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, row.name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, row.kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, row.promptTemplate, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, row.outputMode, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 6, row.enabled ? 1 : 0)
        sqlite3_bind_int(statement, 7, Int32(row.sortOrder))
        sqlite3_bind_int(statement, 8, row.autoSave ? 1 : 0)
        sqlite3_bind_text(statement, 9, row.targetLanguage, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 10, row.icon, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 11, row.isBuiltin ? 1 : 0)
        sqlite3_bind_int(statement, 12, row.thinking ? 1 : 0)
        sqlite3_bind_int(statement, 13, row.speechEnabled ? 1 : 0)
        sqlite3_step(statement)
    }

    static func deleteFeature(id: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM ai_features WHERE id = ?1 AND is_builtin = 0;", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }
}

extension LexiStore {
    /// The Note tool's write: a note row filed under one category
    /// (created on demand — "Tmp" is the tool's default bucket).
    static func insertNote(content: String, category: String = "Tmp") {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO notes (name, content, created_at) VALUES (NULL, ?1, strftime('%Y-%m-%d %H:%M:%S','now'));",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, content, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }

        let id = sqlite3_last_insert_rowid(db)
        let trimmed = category.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        setNoteCategory(id: id, categoryId: noteCategoryIdOrCreate(named: trimmed, db: db))
    }
}

extension LexiStore {
    /// Card notes-tab rename (Rust note-rename handler parity).
    static func updateNoteName(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE notes SET name = ?1 WHERE id = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    /// Notebook detail edit: replace the note body.
    static func updateNoteContent(id: Int64, content: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE notes SET content = ?1 WHERE id = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    /// Set the note's category; nil clears it.
    static func setNoteCategory(id: Int64, categoryId: Int64?) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE notes SET category_id = ?1 WHERE id = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        if let categoryId {
            sqlite3_bind_int64(statement, 1, categoryId)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    /// Categories with live note counts, management order.
    static func noteCategories() -> [LexiNoteCategory] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, """
            SELECT c.id, c.name, (SELECT COUNT(*) FROM notes n WHERE n.category_id = c.id)
            FROM note_categories c ORDER BY c.sort_order, c.id;
            """,
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [LexiNoteCategory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            rows.append(LexiNoteCategory(
                id: sqlite3_column_int64(statement, 0),
                name: name,
                count: Int(sqlite3_column_int64(statement, 2))
            ))
        }
        return rows
    }

    /// Category names are unique; duplicates are silently dropped.
    static func createNoteCategory(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, """
            INSERT OR IGNORE INTO note_categories (name, sort_order)
            VALUES (?1, (SELECT IFNULL(MAX(sort_order), 0) + 1 FROM note_categories));
            """,
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_step(statement)
    }

    static func renameNoteCategory(id: Int64, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE OR IGNORE note_categories SET name = ?1 WHERE id = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmed, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, id)
        sqlite3_step(statement)
    }

    /// Removing a category removes every note filed under it.
    static func deleteNoteCategory(id: Int64) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        var notes: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM notes WHERE category_id = ?1;", -1, &notes, nil) == SQLITE_OK {
            sqlite3_bind_int64(notes, 1, id)
            sqlite3_step(notes)
        }
        sqlite3_finalize(notes)
        var category: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM note_categories WHERE id = ?1;", -1, &category, nil) == SQLITE_OK {
            sqlite3_bind_int64(category, 1, id)
            sqlite3_step(category)
        }
        sqlite3_finalize(category)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    /// Clipboard panel's "移动到分类": save a clip as a note in a category
    /// (the panel deletes its own clip afterwards).
    static func insertNote(name: String, content: String, category: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO notes (name, content) VALUES (?1, ?2);",
            -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, content, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_DONE else { return }

        let id = sqlite3_last_insert_rowid(db)
        let trimmed = category.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        setNoteCategory(id: id, categoryId: noteCategoryIdOrCreate(named: trimmed, db: db))
    }

    /// Category id for a name, creating the row when missing.
    static func noteCategoryIdOrCreate(named name: String, db: OpaquePointer? = nil) -> Int64? {
        let connection: OpaquePointer
        var owned: OpaquePointer?
        if let db {
            connection = db
        } else {
            guard let opened = open() else { return nil }
            owned = opened
            connection = opened
        }
        defer { if let owned { sqlite3_close(owned) } }

        var lookup: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection, "SELECT id FROM note_categories WHERE name = ?1;", -1, &lookup, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(lookup) }
        sqlite3_bind_text(lookup, 1, name, -1, SQLITE_TRANSIENT)
        if sqlite3_step(lookup) == SQLITE_ROW {
            return sqlite3_column_int64(lookup, 0)
        }
        sqlite3_finalize(lookup)

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection,
            "INSERT OR IGNORE INTO note_categories (name, sort_order) VALUES (?1, (SELECT IFNULL(MAX(sort_order), 0) + 1 FROM note_categories));",
            -1, &insert, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(insert) }
        sqlite3_bind_text(insert, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_step(insert)

        var relookup: OpaquePointer?
        guard sqlite3_prepare_v2(
            connection, "SELECT id FROM note_categories WHERE name = ?1;", -1, &relookup, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(relookup) }
        sqlite3_bind_text(relookup, 1, name, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(relookup) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(relookup, 0)
    }

    /// Clipboard panel's drag-to-reorder: each category name gets its
    /// chip-row index as sort_order.
    static func reorderNoteCategories(byNames names: [String]) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "UPDATE note_categories SET sort_order = ?1 WHERE name = ?2;", -1, &statement, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, name) in names.enumerated() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, Int32(index))
            sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }
}

extension LexiStore {
    /// Custom panel tabs (enabled, DB order) — merged with the built-ins
    /// by the caller (panel_config_items parity).
    static func customPanels() -> [(id: String, name: String, icon: String)] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT id, name, IFNULL(icon,'file-text') FROM panels WHERE enabled = 1 ORDER BY sort_order;",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [(String, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let cString = sqlite3_column_text(statement, i) else { return "" }
                return String(cString: cString)
            }
            rows.append((text(0), text(1), text(2)))
        }
        return rows
    }
}

// MARK: - Schema (fresh-install parity with migrations 001-013)

extension LexiStore {
    /// Idempotent schema + seed. Folded final shape of the original 13 SQL
    /// migrations; on an existing DB every statement is a no-op. Runs once
    /// at helper startup.
    static func ensureSchema() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.appendingPathComponent("com.lexi.app", isDirectory: true)
        if let appSupport {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS words (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              word TEXT NOT NULL,
              translation TEXT NOT NULL,
              pos TEXT,
              definition TEXT,
              example TEXT,
              status TEXT NOT NULL DEFAULT 'new',
              created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
              review_count INTEGER NOT NULL DEFAULT 0,
              next_review DATETIME,
              ease_factor REAL NOT NULL DEFAULT 2.5,
              interval INTEGER NOT NULL DEFAULT 0,
              entry_type TEXT NOT NULL DEFAULT 'word',
              source_text TEXT,
              note TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_words_status ON words(status);
            CREATE INDEX IF NOT EXISTS idx_words_next_review ON words(next_review);
            CREATE INDEX IF NOT EXISTS idx_words_word_translation ON words(word, translation);
            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS ai_features (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              kind TEXT NOT NULL,
              prompt_template TEXT NOT NULL,
              output_mode TEXT NOT NULL,
              enabled INTEGER NOT NULL DEFAULT 1,
              sort_order INTEGER NOT NULL DEFAULT 0,
              auto_save_to_vocabulary INTEGER NOT NULL DEFAULT 0,
              target_language TEXT,
              created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
              updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
              review_interval_seconds INTEGER NOT NULL DEFAULT 30,
              speech_enabled INTEGER NOT NULL DEFAULT 0,
              icon TEXT NOT NULL DEFAULT 'wand',
              is_builtin INTEGER NOT NULL DEFAULT 0,
              thinking INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_ai_features_enabled_sort ON ai_features(enabled, sort_order);
            CREATE TABLE IF NOT EXISTS panels (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              icon TEXT NOT NULL DEFAULT 'wand',
              enabled INTEGER NOT NULL DEFAULT 1,
              sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS notes (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT,
              content TEXT NOT NULL,
              created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
            );
            CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(created_at);
            CREATE TABLE IF NOT EXISTS note_categories (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL UNIQUE,
              sort_order INTEGER NOT NULL DEFAULT 0
            );
            INSERT OR IGNORE INTO panels (id, name, icon, enabled, sort_order) VALUES
              ('translate', 'Actions', 'file-text', 1, 0),
              ('review', 'Review', 'book-open', 1, 1);
            INSERT OR IGNORE INTO actions (id, name, icon, toolbar_enabled, toolbar_order, panel_enabled, panel_order, config) VALUES
              ('copy', 'Copy', 'copy', 1, 100, 1, 100, '{}'),
              ('search', 'Search', 'search', 1, 110, 1, 110, '{"engine":"google"}'),
              ('read', 'Read', 'volume', 1, 120, 1, 120, '{"engine":"system"}'),
              ('note', 'Note', 'notebook-pen', 1, 130, 1, 130, '{}'),
              ('handoff', 'Handoff', 'send', 0, 140, 1, 140, '{"targetApp":"ChatGPT"}');
            """, nil, nil, nil)
        migrateNoteCategories()
        migrateActionsTable()
        seedBuiltinFeatures(db: db)
    }

    /// Notes carry one category (nullable = uncategorized). The column is
    /// added idempotently: PRAGMA check, then ALTER TABLE. On DBs from
    /// before the category cutover, legacy per-note tags seed the
    /// categories once: every tag bound to a note becomes a category, and
    /// each still-uncategorized note is filed under the category matching
    /// its first tag.
    static func migrateNoteCategories() {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        var info: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(notes);", -1, &info, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(info) }
        var hasColumn = false
        while sqlite3_step(info) == SQLITE_ROW {
            if let name = sqlite3_column_text(info, 1), String(cString: name) == "category_id" {
                hasColumn = true
                break
            }
        }
        guard hasColumn || sqlite3_exec(
            db,
            "ALTER TABLE notes ADD COLUMN category_id INTEGER REFERENCES note_categories(id);",
            nil, nil, nil
        ) == SQLITE_OK else { return }

        // The legacy tags tables only exist on DBs from before the
        // category cutover — that's the data being migrated in.
        var legacy: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('tags', 'note_tags') GROUP BY 1 HAVING COUNT(*) = 2;",
            -1, &legacy, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(legacy) }
        guard sqlite3_step(legacy) == SQLITE_ROW else { return }

        sqlite3_exec(db, """
            INSERT OR IGNORE INTO note_categories (name, sort_order)
            SELECT t.name, t.sort_order FROM tags t
            WHERE EXISTS (SELECT 1 FROM note_tags nt WHERE nt.tag_id = t.id);
            """, nil, nil, nil)
        sqlite3_exec(db, """
            UPDATE notes SET category_id = (
                SELECT c.id FROM note_tags nt
                JOIN tags t ON t.id = nt.tag_id
                JOIN note_categories c ON c.name = t.name
                WHERE nt.note_id = notes.id
                ORDER BY t.sort_order, t.id
                LIMIT 1
            ) WHERE category_id IS NULL;
            """, nil, nil, nil)
    }

    /// Fresh-install seeds for the four builtin AI features (INSERT OR
    /// IGNORE: existing rows are never touched).
    private static func seedBuiltinFeatures(db: OpaquePointer?) {
        let seeds: [(String, String, String, Int, String, String)] = [
            ("translation", "Translate", "translation", 0, "languages",
             "You are a concise bilingual (English ↔ Chinese) dictionary.\nTranslate the selected text and return Markdown only.\n\nInput:\n<<<TEXT>>>\n{{text}}\n<<<END>>>\n\n1. If the input is an English word:\n- Translate it into Chinese\n- If helpful, analyze it using prefix/suffix\n- Provide English example sentences for common usage\n\n2. If the input is a sentence:\n- Translate it into Chinese\n- Analyze its sentence structure\n- Identify common English patterns in it\n- If helpful, use additional English examples to explain the pattern\n\nOutput:\n- Return as a Markdown bullet list\n- Keep it multi-line\n- Do not add extra sections or labels beyond the above"),
            ("extract", "Extract", "custom", 10, "highlighter",
             "Analyze text as ONE learning point.Use Chinese.\n\n<<<TEXT>>>\n{{text}}\n<<<END>>>\n\nClassify: word / phrase / sentence\n\n- word/phrase: meaning + usage\n- sentence: meaning + structure + pattern\n\nGive 1 example. Keep concise.\n\nReturn Markdown:\n\n### Learning point\n- **Type:**\n- **Meaning:**\n- **Usage:**\n- **Example:**\n- **Note:**"),
            ("rewrite", "Rewrite", "custom", 40, "wand",
             "Rewrite sentences into idiomatic English and flag issues.Use Chinese.\n\n<<<TEXT>>>\n{{text}}\n<<<END>>>\n\nFor each sentence:\n- rewrite naturally\n- list unidiomatic parts\n- brief reason\n\nReturn Markdown list:\n\n- Improved: ...\n- Issues:\n  - ...\n- Explanation:\n  - ..."),
            ("ai", "AI", "custom", 50, "sparkles",
             "Answer the user's question about the following text. Use Chinese.\n\n<<<TEXT>>>\n{{text}}\n<<<END>>>"),
        ]
        for (id, name, kind, order, icon, prompt) in seeds {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT OR IGNORE INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, thinking, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'plain_text', 1, ?5, 0, 'Chinese', 0, ?6, 1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
                -1, &statement, nil
            ) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, prompt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 5, Int32(order))
            sqlite3_bind_text(statement, 6, icon, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
    }
}

// MARK: - Actions table (normalized toolbar_tools)

extension LexiStore {
    /// Create the normalized actions table if absent and seed it from the
    /// JSON blob (once). Dual-write keeps the blob alive for Rust readers
    /// until the cutover deletes them.
    static func migrateActionsTable() {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS actions (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT 'wand',
                toolbar_enabled INTEGER NOT NULL DEFAULT 1,
                toolbar_order INTEGER NOT NULL DEFAULT 100,
                panel_enabled INTEGER NOT NULL DEFAULT 1,
                panel_order INTEGER NOT NULL DEFAULT 100,
                config TEXT NOT NULL DEFAULT '{}'
            );
            """, nil, nil, nil)

        // Seed from the blob only when the table is empty.
        var count: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM actions;", -1, &count, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(count) }
        guard sqlite3_step(count) == SQLITE_ROW, sqlite3_column_int(count, 0) == 0 else { return }

        for entry in toolbarTools() {
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT OR REPLACE INTO actions (id, name, icon, toolbar_enabled, toolbar_order, panel_enabled, panel_order, config)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                """, -1, &insert, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(insert) }
            if let configData = try? JSONSerialization.data(withJSONObject: entry.config),
               let configJson = String(data: configData, encoding: .utf8) {
                sqlite3_bind_text(insert, 1, entry.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 2, entry.displayName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 3, entry.icon, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(insert, 4, entry.enabled ? 1 : 0)
                sqlite3_bind_int(insert, 5, Int32(entry.sortOrder))
                sqlite3_bind_int(insert, 6, entry.panelEnabled ? 1 : 0)
                sqlite3_bind_int(insert, 7, Int32(entry.panelSortOrder))
                sqlite3_bind_text(insert, 8, configJson, -1, SQLITE_TRANSIENT)
                sqlite3_step(insert)
            }
        }
        FileLog.write("ACTIONS table seeded from blob")
    }

    /// Dual-write: the normalized table AND the legacy blob (for Rust).
    static func saveAction(_ entry: LexiToolEntry) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO actions (id, name, icon, toolbar_enabled, toolbar_order, panel_enabled, panel_order, config)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
            """, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        if let configData = try? JSONSerialization.data(withJSONObject: entry.config),
           let configJson = String(data: configData, encoding: .utf8) {
            sqlite3_bind_text(statement, 1, entry.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, entry.displayName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, entry.icon, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 4, entry.enabled ? 1 : 0)
            sqlite3_bind_int(statement, 5, Int32(entry.sortOrder))
            sqlite3_bind_int(statement, 6, entry.panelEnabled ? 1 : 0)
            sqlite3_bind_int(statement, 7, Int32(entry.panelSortOrder))
            sqlite3_bind_text(statement, 8, configJson, -1, SQLITE_TRANSIENT)
            sqlite3_step(statement)
        }
        // Also update the blob for Rust readers.
        var tools = toolbarTools()
        if let index = tools.firstIndex(where: { $0.id == entry.id }) {
            tools[index] = entry
        } else {
            tools.append(entry)
        }
        saveToolbarTools(tools)
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
    /// The shared action registry. Storage stays the `toolbar_tools` JSON
    /// blob until the Rust readers die at cutover; normalization into an
    /// `actions` table happens in that same step (one writer, one format).
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
        // Dual-write: also update the normalized actions table.
        for entry in entries {
            saveAction(entry)
        }
    }

    /// App bundle ids where the selection toolbar stays hidden.
    static func excludedToolbarApps() -> [String] {
        guard let raw = setting("excludedToolbarApps"),
              let data = raw.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return ["com.apple.finder"] }
        return list
    }

    static func saveExcludedToolbarApps(_ list: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: list),
              let raw = String(data: data, encoding: .utf8) else { return }
        setSetting("excludedToolbarApps", raw)
    }

    /// The card's remembered frame ({"x":…,"y":…} / {"width":…,"height":…}).
    static func cardFrame() -> (origin: CGPoint?, size: CGSize?) {
        var origin: CGPoint?
        var size: CGSize?
        if let raw = setting("popupCardPosition"), let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            origin = CGPoint(x: object["x"] ?? 0, y: object["y"] ?? 0)
        }
        if let raw = setting("popupCardSize"), let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
            size = CGSize(width: object["width"] ?? 420, height: object["height"] ?? 420)
        }
        return (origin, size)
    }

    static func resetCardFrame() {
        setSetting("popupCardPosition", "{\"x\":0,\"y\":0}")
        setSetting("popupCardSize", "{\"width\":420,\"height\":420}")
    }
}