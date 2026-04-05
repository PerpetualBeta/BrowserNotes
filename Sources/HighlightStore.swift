import Foundation
import SQLite3

/// Thread-safe SQLite store for browser notes
final class NoteStore: @unchecked Sendable {

    static let shared = NoteStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "cc.jorviksoftware.BrowserNotes.noteDB")

    /// URLs that have at least one note — kept in memory for fast polling checks
    private(set) var urlsWithNotes = Set<String>()

    private init() {}

    func open() {
        queue.sync {
            guard db == nil else { return }

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("BrowserNotes", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let dbFile = dir.appendingPathComponent("notes.db")
            guard sqlite3_open(dbFile.path, &db) == SQLITE_OK else { return }

            let createSQL = """
                CREATE TABLE IF NOT EXISTS notes (
                    id         INTEGER PRIMARY KEY AUTOINCREMENT,
                    url        TEXT NOT NULL,
                    note       TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS idx_notes_url ON notes(url);
                """
            sqlite3_exec(db, createSQL, nil, nil, nil)

            // Migrate from old schema if colour column exists
            migrateFromOldSchema()
            rebuildURLCache()
        }
    }

    private func migrateFromOldSchema() {
        // Migrate from old highlights table if it exists
        var checkStmt: OpaquePointer?
        let checkSQL = "SELECT name FROM sqlite_master WHERE type='table' AND name='highlights'"
        guard sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK else { return }
        let hasHighlights = sqlite3_step(checkStmt) == SQLITE_ROW
        sqlite3_finalize(checkStmt)

        if hasHighlights {
            sqlite3_exec(db, """
                INSERT OR IGNORE INTO notes (url, note, created_at)
                SELECT url, note, created_at FROM highlights WHERE note != ''
                """, nil, nil, nil)
            sqlite3_exec(db, "DROP TABLE IF EXISTS highlights", nil, nil, nil)
        }
    }

    func close() {
        queue.sync {
            if let db { sqlite3_close(db) }
            db = nil
        }
    }

    // MARK: - Save

    @discardableResult
    func save(url: String, note: String) -> Int64? {
        queue.sync {
            guard let db else { return nil }
            let normURL = normaliseURL(url)
            let sql = "INSERT INTO notes (url, note) VALUES (?, ?)"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (normURL as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (note as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            let rowID = sqlite3_last_insert_rowid(db)
            urlsWithNotes.insert(normURL)
            return rowID
        }
    }

    // MARK: - Query

    func notesForURL(_ url: String) -> [SavedNote] {
        queue.sync {
            guard let db else { return [] }
            let normURL = normaliseURL(url)
            let sql = "SELECT id, url, note, created_at FROM notes WHERE url = ? ORDER BY created_at DESC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (normURL as NSString).utf8String, -1, nil)
            var results: [SavedNote] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let n = readRow(stmt) { results.append(n) }
            }
            return results
        }
    }

    func allNotes() -> [SavedNote] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT id, url, note, created_at FROM notes ORDER BY created_at DESC"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var results: [SavedNote] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let n = readRow(stmt) { results.append(n) }
            }
            return results
        }
    }

    // MARK: - Update

    func update(id: Int64, note: String) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE notes SET note = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (note as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Delete

    func delete(id: Int64) {
        queue.sync {
            guard let db else { return }
            let sql = "DELETE FROM notes WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_step(stmt)
            rebuildURLCache()
        }
    }

    // MARK: - Export / Import

    func exportXML() -> String {
        let notes = allNotes()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<browsernotes>\n"
        for note in notes {
            xml += "  <note>\n"
            xml += "    <id>\(note.id)</id>\n"
            xml += "    <url><![CDATA[\(note.url)]]></url>\n"
            xml += "    <text><![CDATA[\(note.note)]]></text>\n"
            xml += "    <created_at>\(note.createdAt)</created_at>\n"
            xml += "  </note>\n"
        }
        xml += "</browsernotes>\n"
        return xml
    }

    /// Imports notes from XML. Inserts new notes; updates existing ones (matched by id) without changing created_at.
    /// Returns the number of notes processed.
    @discardableResult
    func importXML(_ xml: String) -> Int {
        let parser = NoteXMLParser(xml: xml)
        let parsed = parser.parse()
        guard !parsed.isEmpty else { return 0 }

        var count = 0
        queue.sync {
            guard let db else { return }
            for entry in parsed {
                // Try update first (match by id)
                if entry.id > 0 {
                    let updateSQL = "INSERT OR REPLACE INTO notes (id, url, note, created_at) VALUES (?, ?, ?, ?)"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_int64(stmt, 1, entry.id)
                        sqlite3_bind_text(stmt, 2, (entry.url as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 3, (entry.note as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 4, (entry.createdAt as NSString).utf8String, -1, nil)
                        if sqlite3_step(stmt) == SQLITE_DONE { count += 1 }
                        sqlite3_finalize(stmt)
                    }
                } else {
                    let insertSQL = "INSERT INTO notes (url, note, created_at) VALUES (?, ?, ?)"
                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK {
                        sqlite3_bind_text(stmt, 1, (entry.url as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 2, (entry.note as NSString).utf8String, -1, nil)
                        sqlite3_bind_text(stmt, 3, (entry.createdAt as NSString).utf8String, -1, nil)
                        if sqlite3_step(stmt) == SQLITE_DONE { count += 1 }
                        sqlite3_finalize(stmt)
                    }
                }
            }
            rebuildURLCache()
        }
        return count
    }

    // MARK: - Helpers

    private func readRow(_ stmt: OpaquePointer?) -> SavedNote? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        let url = String(cString: sqlite3_column_text(stmt, 1))
        let note = String(cString: sqlite3_column_text(stmt, 2))
        let createdAt = String(cString: sqlite3_column_text(stmt, 3))
        return SavedNote(id: id, url: url, note: note, createdAt: createdAt)
    }

    private func rebuildURLCache() {
        guard let db else { return }
        urlsWithNotes.removeAll()
        let sql = "SELECT DISTINCT url FROM notes"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            urlsWithNotes.insert(String(cString: sqlite3_column_text(stmt, 0)))
        }
    }

    func normaliseURL(_ url: String) -> String {
        var u = url
        if let fragIdx = u.firstIndex(of: "#") { u = String(u[u.startIndex..<fragIdx]) }
        if u.hasSuffix("/") && u.count > 1 {
            let withoutScheme = u.replacingOccurrences(of: "https://", with: "")
                                 .replacingOccurrences(of: "http://", with: "")
            if withoutScheme.filter({ $0 == "/" }).count > 1 { u = String(u.dropLast()) }
        }
        return u
    }
}

// MARK: - XML Parser for import

private final class NoteXMLParser: NSObject, XMLParserDelegate {
    struct ParsedNote {
        var id: Int64 = 0
        var url: String = ""
        var note: String = ""
        var createdAt: String = ""
    }

    private let xml: String
    private var results: [ParsedNote] = []
    private var current: ParsedNote?
    private var currentElement: String = ""
    private var currentText: String = ""

    init(xml: String) { self.xml = xml }

    func parse() -> [ParsedNote] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        currentElement = element
        currentText = ""
        if element == "note" { current = ParsedNote() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let str = String(data: CDATABlock, encoding: .utf8) {
            currentText += str
        }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "id": current?.id = Int64(text) ?? 0
        case "url": current?.url = text
        case "text": current?.note = text
        case "created_at": current?.createdAt = text
        case "note":
            if let entry = current, !entry.url.isEmpty, !entry.note.isEmpty {
                results.append(entry)
            }
            current = nil
        default: break
        }
    }
}
