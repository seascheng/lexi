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
        let sql = "SELECT id, word, translation, IFNULL(pos,''), IFNULL(definition,''), IFNULL(example,''), status, IFNULL(entry_type,'word'), IFNULL(note,''), review_count, strftime('%Y-%m-%d', next_review) FROM words \(whereSQL) ORDER BY created_at DESC, id DESC LIMIT \(limit) OFFSET \(offset);"

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
            let nextReview: String?
            if sqlite3_column_type(statement, 10) == SQLITE_NULL {
                nextReview = nil
            } else {
                nextReview = text(10)
            }
            rows.append(LexiWord(
                id: sqlite3_column_int64(statement, 0),
                word: text(1), translation: text(2), pos: text(3),
                definition: text(4), example: text(5), status: text(6),
                entryType: text(7), note: text(8),
                reviewCount: Int(sqlite3_column_int(statement, 9)),
                nextReview: nextReview
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
            nextReview: nextReview
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
}


/// One notes-table row with its tags.
struct LexiNote: Identifiable, Hashable {
    let id: Int64
    let name: String
    let content: String
    let tags: [String]
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
    /// Latest notes with their tags (the card Notes tab's query, unpagified
    /// for the pane's 200-row window).
    static func notes(limit: Int = 200) -> [LexiNote] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT n.id, IFNULL(n.name,''), n.content, IFNULL((SELECT GROUP_CONCAT(t.name) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id), '') FROM notes n ORDER BY n.created_at DESC, n.id DESC LIMIT \(limit);",
            -1, &statement, nil
        ) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [LexiNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let cString = sqlite3_column_text(statement, i) else { return "" }
                return String(cString: cString)
            }
            let tagList = text(3).split(whereSeparator: { $0 == "," }).map(String.init)
            rows.append(LexiNote(id: sqlite3_column_int64(statement, 0), name: text(1), content: text(2), tags: tagList))
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
            "SELECT id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, IFNULL(target_language,''), icon, is_builtin, thinking FROM ai_features ORDER BY sort_order, created_at;",
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
                thinking: sqlite3_column_int64(statement, 11) == 1
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
            "INSERT INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, icon, is_builtin, thinking, updated_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12, datetime('now')) ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, prompt_template=excluded.prompt_template, output_mode=excluded.output_mode, enabled=excluded.enabled, sort_order=excluded.sort_order, auto_save_to_vocabulary=excluded.auto_save_to_vocabulary, target_language=excluded.target_language, icon=excluded.icon, thinking=excluded.thinking, updated_at=datetime('now');",
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

/// One entry of the shared action registry (`toolbar_tools` blob): the
/// toolbar scope and the card's Actions-tab scope each read their columns.
struct LexiToolEntry: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var enabled: Bool
    var sortOrder: Int
    var panelEnabled: Bool
    var panelSortOrder: Int
    var icon: String
    var config: [String: String]
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