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
