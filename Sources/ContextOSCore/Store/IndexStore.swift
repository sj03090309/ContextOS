import Foundation
import SQLite3

/// Errors thrown by the SQLite index store.
public enum IndexStoreError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String)
    case step(String)

    public var description: String {
        switch self {
        case .open(let m): return "Failed to open index database: \(m)"
        case .prepare(let m): return "Failed to prepare statement: \(m)"
        case .step(let m): return "Failed to execute statement: \(m)"
        }
    }
}

/// The on-disk index. Thin, hand-rolled wrapper over the system SQLite3.
///
/// Not thread-safe: use one instance per thread/task. M1 drives it synchronously
/// from the CLI, so this is fine; the MCP server (M3) will own its own instance.
public final class IndexStore {

    private var db: OpaquePointer?

    // SQLite wants the string bytes to outlive the bind call; TRANSIENT makes it copy.
    private static let SQLITE_TRANSIENT = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    /// Open (or create) a database at `path`. Pass ":memory:" for tests.
    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw IndexStoreError.open(message)
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createSchema() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS files (
            id           INTEGER PRIMARY KEY,
            path         TEXT NOT NULL UNIQUE,
            language     TEXT NOT NULL,
            byte_size    INTEGER NOT NULL,
            line_count   INTEGER NOT NULL,
            content_hash TEXT NOT NULL,
            modified_at  REAL NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS symbols (
            id      INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            name    TEXT NOT NULL,
            kind    TEXT NOT NULL,
            line    INTEGER NOT NULL
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS imports (
            id      INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            module  TEXT NOT NULL,
            line    INTEGER NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);")
        try exec("CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_imports_module ON imports(module);")
    }

    /// Wipe all indexed data (used before a full re-index).
    public func reset() throws {
        try exec("DELETE FROM imports;")
        try exec("DELETE FROM symbols;")
        try exec("DELETE FROM files;")
    }

    // MARK: - Writes

    public func beginTransaction() throws { try exec("BEGIN;") }
    public func commit() throws { try exec("COMMIT;") }

    /// Insert a file row and return its rowid.
    @discardableResult
    public func insertFile(_ file: IndexedFile) throws -> Int64 {
        let sql = """
        INSERT INTO files (path, language, byte_size, line_count, content_hash, modified_at)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, file.relativePath)
        bindText(stmt, 2, file.language.rawValue)
        sqlite3_bind_int64(stmt, 3, Int64(file.byteSize))
        sqlite3_bind_int64(stmt, 4, Int64(file.lineCount))
        bindText(stmt, 5, file.contentHash)
        sqlite3_bind_double(stmt, 6, file.modifiedAt)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func insertSymbol(_ symbol: Symbol, fileID: Int64) throws {
        let stmt = try prepare("INSERT INTO symbols (file_id, name, kind, line) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileID)
        bindText(stmt, 2, symbol.name)
        bindText(stmt, 3, symbol.kind.rawValue)
        sqlite3_bind_int64(stmt, 4, Int64(symbol.line))
        try step(stmt)
    }

    public func insertImport(_ edge: ImportEdge, fileID: Int64) throws {
        let stmt = try prepare("INSERT INTO imports (file_id, module, line) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileID)
        bindText(stmt, 2, edge.module)
        sqlite3_bind_int64(stmt, 3, Int64(edge.line))
        try step(stmt)
    }

    // MARK: - Reads

    public func fileCount() throws -> Int { try scalarCount("SELECT COUNT(*) FROM files;") }
    public func symbolCount() throws -> Int { try scalarCount("SELECT COUNT(*) FROM symbols;") }
    public func importCount() throws -> Int { try scalarCount("SELECT COUNT(*) FROM imports;") }

    /// File counts grouped by language, for stats display.
    public func fileCountByLanguage() throws -> [Language: Int] {
        let stmt = try prepare("SELECT language, COUNT(*) FROM files GROUP BY language;")
        defer { sqlite3_finalize(stmt) }
        var result: [Language: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let raw = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            result[Language(rawValue: raw) ?? .unknown] = count
        }
        return result
    }

    /// Load every indexed file (with rowid populated). Small projects only —
    /// the optimizer pulls the whole index into memory to rank it.
    public func allFiles() throws -> [IndexedFile] {
        let stmt = try prepare("""
        SELECT id, path, language, byte_size, line_count, content_hash, modified_at FROM files;
        """)
        defer { sqlite3_finalize(stmt) }
        var out: [IndexedFile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(
                IndexedFile(
                    id: sqlite3_column_int64(stmt, 0),
                    relativePath: columnText(stmt, 1),
                    language: Language(rawValue: columnText(stmt, 2)) ?? .unknown,
                    byteSize: Int(sqlite3_column_int64(stmt, 3)),
                    lineCount: Int(sqlite3_column_int64(stmt, 4)),
                    contentHash: columnText(stmt, 5),
                    modifiedAt: sqlite3_column_double(stmt, 6)
                )
            )
        }
        return out
    }

    /// All symbols, grouped by their owning file's rowid.
    public func symbolsByFile() throws -> [Int64: [Symbol]] {
        let stmt = try prepare("SELECT file_id, name, kind, line FROM symbols;")
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: [Symbol]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fileID = sqlite3_column_int64(stmt, 0)
            let symbol = Symbol(
                name: columnText(stmt, 1),
                kind: SymbolKind(rawValue: columnText(stmt, 2)) ?? .variable,
                line: Int(sqlite3_column_int64(stmt, 3))
            )
            out[fileID, default: []].append(symbol)
        }
        return out
    }

    /// All import edges, grouped by their owning file's rowid.
    public func importsByFile() throws -> [Int64: [ImportEdge]] {
        let stmt = try prepare("SELECT file_id, module, line FROM imports;")
        defer { sqlite3_finalize(stmt) }
        var out: [Int64: [ImportEdge]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fileID = sqlite3_column_int64(stmt, 0)
            let edge = ImportEdge(
                module: columnText(stmt, 1),
                line: Int(sqlite3_column_int64(stmt, 2))
            )
            out[fileID, default: []].append(edge)
        }
        return out
    }

    // MARK: - Low-level helpers

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errmsg) != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw IndexStoreError.step(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            throw IndexStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer?) throws {
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw IndexStoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalarCount(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
    }
}
