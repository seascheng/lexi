import Foundation
import SQLite3

/// Access to the main Lexi database. Values are plain TEXT key/value rows
/// in `settings`; every statement runs over ONE process-wide connection
/// (FULLMUTEX + busy timeout), so concurrent access simply serializes.
enum LexiStore {
    /// `SQLITE_TRANSIENT` is a C macro, invisible to Swift.
    static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Bind/read conveniences (statement pointers only)

    @inline(__always) static func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
    }

    @inline(__always) static func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int32) {
        sqlite3_bind_int(stmt, index, value)
    }

    @inline(__always) static func bindInt64(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    @inline(__always) static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }

    @inline(__always) static func columnOptionalText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : columnText(stmt, index)
    }

    /// `com.lexi.app` is the data directory's identifier; the helper is a
    /// different bundle, so the path is spelled out rather than derived
    /// from Bundle.main. Shared by `databasePath` and `ensureSchema`, which
    /// previously built this path separately.
    static let appSupportDirectory: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("com.lexi.app", isDirectory: true)

    /// Settable so the store harness can run against a scratch database.
    static var databasePath: String = {
        appSupportDirectory?.appendingPathComponent("lexi.db").path ?? ""
    }()

    /// One lazily-opened, process-wide connection (app lifetime).
    private static var db: OpaquePointer?
    private static let openLock = NSLock()

    static func open() -> OpaquePointer? {
        openLock.lock()
        defer { openLock.unlock() }
        if let db { return db }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databasePath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2_000)
        db = handle
        return handle
    }

    /// Run one non-row statement (INSERT/UPDATE/DELETE/DDL).
    @discardableResult
    static func run(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }) -> Bool {
        guard let db = open() else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement!)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    /// Step through every result row; `row` reads columns off the statement.
    @discardableResult
    static func query(
        _ sql: String,
        _ bind: (OpaquePointer) -> Void = { _ in },
        _ row: (OpaquePointer) -> Void
    ) -> Bool {
        guard let db = open() else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement!)
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement!)
        }
        return true
    }

    // MARK: - Settings KV

    /// Settings table row read. Returns nil when the key is absent.
    static func setting(_ key: String) -> String? {
        var value: String?
        query("SELECT value FROM settings WHERE key = ?1 LIMIT 1;", { bindText($0, 1, key) }) { stmt in
            value = columnText(stmt, 0)
        }
        return value
    }

    /// Upsert one settings row.
    static func setSetting(_ key: String, _ value: String) {
        run("INSERT INTO settings (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value;") {
            bindText($0, 1, key)
            bindText($0, 2, value)
        }
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

// MARK: - Schema (fresh-install parity with migrations 001-013)

extension LexiStore {
    /// Idempotent schema + seed. Folded final shape of the original 13 SQL
    /// migrations; on an existing DB every statement is a no-op. Runs once
    /// at helper startup.
    static func ensureSchema() {
        if let appSupport = appSupportDirectory {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        guard let db = open() else { return }

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
              speech_enabled INTEGER NOT NULL DEFAULT 0,
              icon TEXT NOT NULL DEFAULT 'wand',
              is_builtin INTEGER NOT NULL DEFAULT 0,
              thinking INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_ai_features_enabled_sort ON ai_features(enabled, sort_order);
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
            -- Cutover cleanup: these shadow tables existed for the retired
            -- Rust reader (actions mirrored the toolbar_tools blob) and a
            -- never-shipped custom-panels feature. Single sources now: the
            -- settings blob and the built-in constants.
            DROP TABLE IF EXISTS actions;
            DROP TABLE IF EXISTS panels;
            """, nil, nil, nil)
        migrateNoteCategories()
        migratePanelColumns()
        migrateTmpCategoryToNote()
        seedBuiltinFeatures()
    }

    /// The toolbar note tool's default bucket was "Tmp"; the fixed chip is
    /// "Note" now. Rename in place when no Note category exists, else merge
    /// Tmp's notes into Note and drop Tmp. Idempotent.
    private static func migrateTmpCategoryToNote() {
        guard let db = open() else { return }
        sqlite3_exec(db, """
            UPDATE note_categories SET name = 'Note' WHERE name = 'Tmp'
              AND NOT EXISTS (SELECT 1 FROM note_categories WHERE name = 'Note');
            """, nil, nil, nil)
        sqlite3_exec(db, """
            UPDATE notes SET category_id =
              (SELECT id FROM note_categories WHERE name = 'Note')
            WHERE category_id = (SELECT id FROM note_categories WHERE name = 'Tmp');
            """, nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM note_categories WHERE name = 'Tmp';", nil, nil, nil)
    }

    /// Clipboard-panel columns, added idempotently (PRAGMA + ALTER):
    /// notes.sort_order (manual per-category order from row drag-reorder)
    /// and note_categories.color (chip color picker).
    static func migratePanelColumns() {
        guard let db = open() else { return }

        var hasSort = false
        query("PRAGMA table_info(notes);") { stmt in
            if columnText(stmt, 1) == "sort_order" { hasSort = true }
        }
        if !hasSort {
            _ = sqlite3_exec(db, "ALTER TABLE notes ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        }

        var hasColor = false
        query("PRAGMA table_info(note_categories);") { stmt in
            if columnText(stmt, 1) == "color" { hasColor = true }
        }
        if !hasColor {
            _ = sqlite3_exec(db, "ALTER TABLE note_categories ADD COLUMN color TEXT;", nil, nil, nil)
        }
    }

    /// Notes carry one category (nullable = uncategorized). The column is
    /// added idempotently: PRAGMA check, then ALTER TABLE. On DBs from
    /// before the category cutover, legacy per-note tags seed the
    /// categories once: every tag bound to a note becomes a category, and
    /// each still-uncategorized note is filed under the category matching
    /// its first tag.
    static func migrateNoteCategories() {
        guard let db = open() else { return }

        var hasColumn = false
        query("PRAGMA table_info(notes);") { stmt in
            if columnText(stmt, 1) == "category_id" {
                hasColumn = true
            }
        }
        guard hasColumn || sqlite3_exec(
            db,
            "ALTER TABLE notes ADD COLUMN category_id INTEGER REFERENCES note_categories(id);",
            nil, nil, nil
        ) == SQLITE_OK else { return }

        // The legacy tags tables only exist on DBs from before the
        // category cutover — that's the data being migrated in.
        var hasLegacy = false
        query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name IN ('tags', 'note_tags') GROUP BY 1 HAVING COUNT(*) = 2;"
        ) { _ in hasLegacy = true }
        guard hasLegacy else { return }

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
    private static func seedBuiltinFeatures() {
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
            run(
                "INSERT OR IGNORE INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, icon, is_builtin, thinking, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 'plain_text', 1, ?5, 0, 'Chinese', ?6, 1, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);",
                {
                    bindText($0, 1, id)
                    bindText($0, 2, name)
                    bindText($0, 3, kind)
                    bindText($0, 4, prompt)
                    bindInt($0, 5, Int32(order))
                    bindText($0, 6, icon)
                })
        }
    }
}
