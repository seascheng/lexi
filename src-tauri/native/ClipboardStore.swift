import Foundation
import SQLite3

// Clipboard history storage — Foundation + SQLite3 only, ported from
// tinycast's ClipboardStore (docs/features/clipboard.md invariants):
//
// - kind holds only what capture can tell apart on the pasteboard
//   (text/image/file); a link or colour is DERIVED from the text at display
//   time, never persisted (ClipboardFilter.link below).
// - a .file entry references the file where it lies: its absolute path is the
//   `text` column and imagePath stays nil, so delete/prune can never reach a
//   file we didn't write.
// - resident window: every pinned row plus the newest `windowSize` unpinned
//   rows, loaded as two indexed branches (a single OR cannot be driven from
//   an index while preserving row order).
// - promote rewrites a row under the same id (delete + re-insert inside one
//   transaction) so stored order is rowid order.
// - a database that cannot be opened is deleted and recreated once; beyond
//   that the store degrades to a session-only in-memory window.

/// Display-time exclusive filter (tinycast ClipboardFilter semantics): a
/// copied URL is a link, not a narrower kind of text.
enum ClipboardFilter: Equatable {
    case all
    case pinned
    case text
    case link
    case file

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .pinned: return item.pinnedAt != nil
        case .text: return item.kind == .text && !ClipboardFilter.looksLikeLink(item.text)
        case .link: return item.kind == .text && ClipboardFilter.looksLikeLink(item.text)
        case .file: return item.kind == .file
        }
    }

    /// Derived, cheapest-first: size gate, scheme prefix, mailto. No bare
    /// domain heuristic in v1 — `report.pdf` stays text.
    static func looksLikeLink(_ text: String?) -> Bool {
        guard let text, text.utf8.count <= 2048 else { return false }
        if text.utf8.count > 0 {
            let lower = text.lowercased()
            if lower.hasPrefix("mailto:") { return true }
            if let colon = lower.firstIndex(of: ":") {
                let scheme = lower[..<colon]
                let allowed = scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
                if allowed, let first = scheme.first, first.isLetter, !text.contains(" ") {
                    return true
                }
            }
        }
        return false
    }
}

struct ClipboardItem: Equatable {
    enum Kind: String {
        case text, image, file
    }

    let id: UUID
    let kind: Kind
    /// The copied text, or for a `.file` entry the absolute path.
    let text: String?
    /// Absolute path of OUR OWN image blob under images/; nil for anything
    /// but .image — which is what keeps delete/prune from ever reaching a
    /// file we did not write.
    let imagePath: String?
    let createdAt: Date
    let sourceBundleID: String?
    /// A stamp, not a flag: the Pinned section is ordered by when you pinned.
    let pinnedAt: Date?

    var filePath: String? { kind == .file ? text : nil }

    /// Preview text for list rows (image rows have none).
    var previewText: String? {
        switch kind {
        case .text, .file: return text
        case .image: return nil
        }
    }
}

final class ClipboardStore {
    /// Newest unpinned rows kept resident; everything older is reachable via
    /// FTS search only.
    static let windowSize = 1000
    /// Unpinned rows older than this are pruned; pins survive.
    static let retentionDays: TimeInterval = 90

    private var db: OpaquePointer?
    private let directory: URL
    private let imagesDir: URL

    /// Resident window in stored order (newest first): pinned rows stay in
    /// pure recency position here; the display split is the panel's job.
    private(set) var items: [ClipboardItem] = []

    private var insertStmt: OpaquePointer?
    private var deleteByIDStmt: OpaquePointer?
    private var pinStmt: OpaquePointer?
    private var windowFloorStmt: OpaquePointer?
    private var searchStmt: OpaquePointer?
    private var staleStmt: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the store under the helper's Application
    /// Support directory. A database that cannot be opened is deleted and
    /// recreated once — a history is captured rather than authored. If that
    /// fails too, the store degrades to an empty in-memory window.
    /// Convenience: tests inject a scratch directory — NSHomeDirectory()
    /// ignores the HOME environment variable, so Application Support cannot
    /// be redirected from the environment.
    static func open() -> ClipboardStore? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return open(
            directory: base.appendingPathComponent("com.lexi.selection-helper", isDirectory: true),
            imagesDirectoryName: "images"
        )
    }

    static func open(directory: URL, imagesDirectoryName: String) -> ClipboardStore? {
        let fileManager = FileManager.default
        let imagesDir = directory.appendingPathComponent(imagesDirectoryName, isDirectory: true)
        for dir in [directory, imagesDir] {
            if !fileManager.fileExists(atPath: dir.path) {
                try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let store = ClipboardStore(directory: directory, imagesDir: imagesDir)
        if store.openDatabase() { return store }
        // Wipe and retry once.
        try? fileManager.removeItem(at: directory.appendingPathComponent("clipboard.sqlite3"))
        if store.openDatabase() { return store }
        FileLog.write("CLIP store unavailable — running in-memory")
        return store
    }

    private init(directory: URL, imagesDir: URL) {
        self.directory = directory
        self.imagesDir = imagesDir
    }

    private func openDatabase() -> Bool {
        let path = directory.appendingPathComponent("clipboard.sqlite3").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout=1000;", nil, nil, nil)
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else {
            return false
        }
        insertStmt = prepare(Self.insertSQL)
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        pinStmt = prepare("UPDATE items SET pinned_at = ? WHERE id = ?")
        // Only ever sets a stamp; unpinning rewrites the whole row so it
        // leads the history again (promote semantics).
        windowFloorStmt = prepare("SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET ?")
        searchStmt = prepare(
            """
            SELECT i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at
            FROM items_fts f JOIN items i ON i.rowid = f.rowid
            WHERE items_fts MATCH ? ORDER BY f.rowid DESC LIMIT 200
            """)
        staleStmt = prepare("SELECT image_path FROM items WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL")
        guard insertStmt != nil, deleteByIDStmt != nil, pinStmt != nil, windowFloorStmt != nil,
              searchStmt != nil, staleStmt != nil
        else { return false }
        load()
        prune()
        return true
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text TEXT,
          image_path TEXT,
          created_at REAL NOT NULL,
          source_app TEXT,
          pinned_at REAL
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          text, content='items', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS items_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS items_au AFTER UPDATE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
          INSERT INTO items_fts(rowid, text) VALUES (new.rowid, new.text);
        END;
        """

    private static let insertSQL = """
        INSERT INTO items(id, kind, text, image_path, created_at, source_app, pinned_at)
        VALUES(?,?,?,?,?,?,?)
        """

    deinit {
        for stmt in [insertStmt, deleteByIDStmt, pinStmt, windowFloorStmt, searchStmt, staleStmt] {
            sqlite3_finalize(stmt)
        }
        if db != nil { sqlite3_close(db) }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    // MARK: load

    /// Two indexed branches: every pinned row plus the newest `windowSize`
    /// unpinned ones, newest first. The floor is 0 — no floor, load everything
    /// — while the history is shorter than the window.
    private func load() {
        var floorRowid: Int64 = 0
        if let stmt = windowFloorStmt {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(Self.windowSize - 1))
            if sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_value(stmt, 0) {
                floorRowid = sqlite3_value_int64(value)
            }
            sqlite3_reset(stmt)
        }
        let sql = """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at FROM (
              SELECT rowid AS rid, * FROM items WHERE rowid >= ?1
              UNION ALL
              SELECT rowid AS rid, * FROM items WHERE pinned_at IS NOT NULL AND rowid < ?1
            ) ORDER BY rid DESC
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, floorRowid)

        var loaded: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = Self.item(from: stmt) { loaded.append(item) }
        }
        items = loaded
    }

    private static func item(from stmt: OpaquePointer) -> ClipboardItem? {
        guard let idString = columnString(stmt, 0), let id = UUID(uuidString: idString),
              let kindString = columnString(stmt, 1),
              let kind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        let text = columnString(stmt, 2)
        let imagePath = columnString(stmt, 3)
        // A file row always has its path; an image row always has its blob
        // path; text rows have text. Anything else cannot round-trip.
        switch kind {
        case .text where text == nil: return nil
        case .image where imagePath == nil: return nil
        case .file where text == nil: return nil
        default: break
        }
        return ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
            sourceBundleID: columnString(stmt, 5),
            pinnedAt: columnDate(stmt, 6))
    }

    private static func columnString(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private static func columnDate(_ stmt: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    // MARK: capture

    /// Re-copy semantics: a repeat of the leading row is the same ⌘C (no-op);
    /// an older row with the same content moves to the top instead of
    /// duplicating (Maccy/Paste semantics — keeps search duplicate-free).
    func addText(_ text: String, sourceBundleID: String?) {
        if let first = items.first, first.kind == .text, first.text == text { return }
        if let existing = items.first(where: { $0.kind == .text && $0.text == text }) {
            promote(existing)
            return
        }
        insert(ClipboardItem(
            id: UUID(), kind: .text, text: text, imagePath: nil,
            createdAt: Date(), sourceBundleID: sourceBundleID, pinnedAt: nil))
    }

    /// Multiple files arrive oldest-last: reversed so the FIRST file copied
    /// ends up leading the history. A single-file repeat promotes its row
    /// (same rule as addText).
    func addFiles(_ paths: [String], sourceBundleID: String?) {
        for path in paths.reversed() {
            if let first = items.first, first.kind == .file, first.text == path { continue }
            if let existing = items.first(where: { $0.kind == .file && $0.text == path }) {
                promote(existing)
                continue
            }
            insert(ClipboardItem(
                id: UUID(), kind: .file, text: path, imagePath: nil,
                createdAt: Date(), sourceBundleID: sourceBundleID, pinnedAt: nil))
        }
    }

    /// Writes the PNG blob under images/ and inserts the row. Returns the
    /// item, or nil when the blob could not be stored.
    @discardableResult
    func addImage(_ png: Data, sourceBundleID: String?) -> ClipboardItem? {
        let item = ClipboardItem(
            id: UUID(), kind: .image, text: nil,
            imagePath: imagesDir.appendingPathComponent(UUID().uuidString + ".png").path,
            createdAt: Date(), sourceBundleID: sourceBundleID, pinnedAt: nil)
        do {
            try png.write(to: URL(fileURLWithPath: item.imagePath!), options: .atomic)
        } catch {
            FileLog.write("CLIP image blob write failed: \(error)")
            return nil
        }
        insert(item)
        return item
    }

    private func insert(_ item: ClipboardItem) {
        guard let stmt = insertStmt else { return }
        sqlite3_reset(stmt)
        bind(item, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            sqlite3_reset(stmt)
            return
        }
        sqlite3_reset(stmt)
        items.insert(item, at: 0)
        trimWindow()
    }

    private func bind(_ item: ClipboardItem, to stmt: OpaquePointer) {
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, Self.transient)
        if let text = item.text {
            sqlite3_bind_text(stmt, 3, text, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let imagePath = item.imagePath {
            sqlite3_bind_text(stmt, 4, imagePath, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        if let sourceBundleID = item.sourceBundleID {
            sqlite3_bind_text(stmt, 6, sourceBundleID, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let pinnedAt = item.pinnedAt {
            sqlite3_bind_double(stmt, 7, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
    }

    /// Keep the resident window at `windowSize` unpinned rows (pins exempt).
    private func trimWindow() {
        var unpinned = 0
        var cutAt: Int?
        for (index, item) in items.enumerated() {
            if item.pinnedAt != nil { continue }
            unpinned += 1
            if unpinned > Self.windowSize { cutAt = index; break }
        }
        if let cutAt { items.removeSubrange(cutAt...) }
    }

    func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3, db != nil {
            let hits = searchFTS(trimmed, filter: filter)
            let lower = trimmed.lowercased()
            let pinned = items.filter {
                $0.pinnedAt != nil && filter.matches($0) && inMemoryMatch($0, query: lower)
            }
            var seen = Set<UUID>()
            return (pinned + hits).filter { seen.insert($0.id).inserted }
        }
        let lower = trimmed.lowercased()
        return items.filter { filter.matches($0) && inMemoryMatch($0, query: lower) }
    }

    private func inMemoryMatch(_ item: ClipboardItem, query lower: String) -> Bool {
        guard !lower.isEmpty else { return true }
        guard let text = item.previewText else { return false }
        return text.lowercased().contains(lower)
    }

    private func searchFTS(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        guard let stmt = searchStmt else { return [] }
        // FTS5 phrase syntax: wrap as a quoted string so punctuation in the
        // query is never read as query syntax.
        let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, phrase, -1, Self.transient)
        var found: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // FTS knows nothing of the exclusive display filter — apply after.
            if let item = Self.item(from: stmt), filter.matches(item) { found.append(item) }
        }
        sqlite3_reset(stmt)
        return found
    }

    // MARK: mutations

    /// Re-under the same id so the row leads the history: stored order is
    /// rowid order, so this is a delete plus re-insert inside one
    /// transaction — a crash between the two statements must not lose the
    /// row. Pinned rows skip promote: pasting a pin holds its place.
    func promote(_ item: ClipboardItem) {
        guard item.pinnedAt == nil else { return }
        guard let stmt = insertStmt, let delete = deleteByIDStmt else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        sqlite3_reset(delete)
        sqlite3_bind_text(delete, 1, item.id.uuidString, -1, Self.transient)
        _ = sqlite3_step(delete)
        sqlite3_reset(delete)
        sqlite3_reset(stmt)
        bind(item, to: stmt)
        let inserted = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_reset(stmt)
        if inserted {
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        }
        items.insert(item, at: 0)
    }

    /// Pin sets a stamp only. Unpin re-recencies the row (delete + re-insert
    /// so it leads the history again — Raycast semantics).
    func setPinned(_ item: ClipboardItem, pinned: Bool) {
        if pinned {
            guard let stmt = pinStmt else { return }
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, item.id.uuidString, -1, Self.transient)
            _ = sqlite3_step(stmt)
            sqlite3_reset(stmt)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item.withPinnedAt(Date())
            }
        } else {
            promote(item.withPinnedAt(nil))
        }
    }

    /// Deletes the row and any blob WE own under images/. A .file entry's
    /// referenced file is never touched — the row only pointed at it.
    func delete(_ item: ClipboardItem) {
        guard let stmt = deleteByIDStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.transient)
        _ = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if let imagePath = item.imagePath, ownsBlob(at: imagePath) {
            try? FileManager.default.removeItem(atPath: imagePath)
        }
        items.removeAll { $0.id == item.id }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard item.kind == .image, let imagePath = item.imagePath, ownsBlob(at: imagePath) else {
            return nil
        }
        return URL(fileURLWithPath: imagePath)
    }

    /// The one ownership rule: a path under our own images/ directory is ours
    /// to delete; anything else is an external reference we leave on disk.
    private func ownsBlob(at path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.absoluteString
            .hasPrefix(imagesDir.standardizedFileURL.absoluteString)
    }

    /// Retention cut: unpinned rows older than `retentionDays`; pins survive.
    /// Own image blobs go with their rows, off this thread's hot path is the
    /// caller's concern (capture calls this at most once per open).
    func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 86_400)
        if let stmt = staleStmt {
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = Self.columnString(stmt, 0), ownsBlob(at: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            sqlite3_reset(stmt)
        }
        var deleteStmt: OpaquePointer?
        defer { sqlite3_finalize(deleteStmt) }
        guard sqlite3_prepare_v2(
            db, "DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL", -1, &deleteStmt, nil
        ) == SQLITE_OK else { return }
        sqlite3_bind_double(deleteStmt, 1, cutoff.timeIntervalSince1970)
        _ = sqlite3_step(deleteStmt)
        items.removeAll { $0.pinnedAt == nil && $0.createdAt < cutoff }
    }
}

extension ClipboardItem {
    func withPinnedAt(_ date: Date?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            createdAt: createdAt, sourceBundleID: sourceBundleID, pinnedAt: date)
    }
}
