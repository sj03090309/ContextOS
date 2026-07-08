import Foundation
import CryptoKit

/// Orchestrates a full index build: scan → read → parse → persist.
///
/// This is the entry point the CLI (and later the MCP server) calls. It owns the
/// pipeline wiring but delegates each concern to a focused type, so pieces can be
/// swapped independently (e.g. `HeuristicParser` → a Tree-sitter parser).
public struct Indexer {

    public let scanner: ProjectScanner
    public let parser: LanguageParser

    public init(
        scanner: ProjectScanner = ProjectScanner(),
        parser: LanguageParser = HeuristicParser()
    ) {
        self.scanner = scanner
        self.parser = parser
    }

    /// Where the index database lives for a given project root.
    public static func databaseURL(forProjectRoot root: URL) -> URL {
        root.appendingPathComponent(".contextos", isDirectory: true)
            .appendingPathComponent("index.sqlite")
    }

    /// Build (or rebuild) the index for `projectRoot`.
    ///
    /// M1 always does a full rebuild. Incremental indexing (via `contentHash`)
    /// is a later optimization; the schema already stores what it needs.
    @discardableResult
    public func index(projectRoot: URL) throws -> IndexStats {
        let start = Date()

        let dbURL = Self.databaseURL(forProjectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let store = try IndexStore(path: dbURL.path)
        try store.reset()

        let files = try scanner.scan(root: projectRoot)

        var stats = IndexStats()
        try store.beginTransaction()

        for scanned in files {
            guard let data = try? Data(contentsOf: scanned.absoluteURL),
                  let source = String(data: data, encoding: .utf8)
            else {
                // Unreadable or non-UTF8 (binary that slipped past the filter).
                stats.filesSkipped += 1
                continue
            }

            let hash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            let lineCount = source.reduce(into: 1) { count, ch in
                if ch == "\n" { count += 1 }
            }

            let file = IndexedFile(
                relativePath: scanned.relativePath,
                language: scanned.language,
                byteSize: scanned.byteSize,
                lineCount: lineCount,
                contentHash: hash,
                modifiedAt: scanned.modifiedAt
            )
            let fileID = try store.insertFile(file)
            stats.filesIndexed += 1
            stats.byLanguage[scanned.language, default: 0] += 1

            guard parser.supports(scanned.language) else { continue }
            let parsed = parser.parse(source: source, language: scanned.language)
            for symbol in parsed.symbols {
                try store.insertSymbol(symbol, fileID: fileID)
                stats.symbolsIndexed += 1
            }
            for edge in parsed.imports {
                try store.insertImport(edge, fileID: fileID)
                stats.importsIndexed += 1
            }
        }

        try store.commit()
        stats.duration = Date().timeIntervalSince(start)
        return stats
    }

    /// Open the store for an already-indexed project (for `stats`, later queries).
    public static func openStore(forProjectRoot root: URL) throws -> IndexStore {
        let dbURL = databaseURL(forProjectRoot: root)
        return try IndexStore(path: dbURL.path)
    }
}
