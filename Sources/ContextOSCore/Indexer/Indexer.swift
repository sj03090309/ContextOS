import Foundation
import CryptoKit

/// Orchestrates a full index build: scan → read → parse → persist.
///
/// This is the entry point the CLI (and later the MCP server) calls. It owns the
/// pipeline wiring but delegates each concern to a focused type, so pieces can be
/// swapped independently (e.g. `HeuristicParser` → a Tree-sitter parser).
public struct Indexer: Sendable {

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
    /// Incremental: files whose size + mtime are unchanged are left as-is; only
    /// new or modified files are re-read/parsed, and files removed from disk are
    /// dropped. The `contentHash` guards against mtime-only touches. This makes
    /// the watcher's per-save re-index cheap on large projects.
    @discardableResult
    public func index(projectRoot: URL) throws -> IndexStats {
        let start = Date()

        let dbURL = Self.databaseURL(forProjectRoot: projectRoot)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let store = try IndexStore(path: dbURL.path)

        // Snapshot of what's already indexed, keyed by path.
        var existing: [String: IndexedFile] = [:]
        for f in try store.allFiles() { existing[f.relativePath] = f }

        let files = try scanner.scan(root: projectRoot)
        var seenPaths = Set<String>()

        var stats = IndexStats()
        try store.beginTransaction()

        for scanned in files {
            seenPaths.insert(scanned.relativePath)
            stats.byLanguage[scanned.language, default: 0] += 1
            stats.filesIndexed += 1

            // Fast path: unchanged size + mtime → skip entirely (no read/parse).
            if let prior = existing[scanned.relativePath],
               prior.byteSize == scanned.byteSize,
               prior.modifiedAt == scanned.modifiedAt {
                continue
            }

            guard let data = try? Data(contentsOf: scanned.absoluteURL),
                  let source = String(data: data, encoding: .utf8)
            else {
                stats.filesSkipped += 1
                stats.filesIndexed -= 1
                if let prior = existing[scanned.relativePath], let id = prior.id {
                    try store.deleteFile(id: id) // became unreadable/binary
                }
                continue
            }

            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

            // Content identical (mtime-only touch): just refresh metadata.
            if let prior = existing[scanned.relativePath], prior.contentHash == hash, let id = prior.id {
                try store.updateFileMeta(id: id, byteSize: scanned.byteSize, modifiedAt: scanned.modifiedAt)
                continue
            }

            // New or genuinely changed: replace the file's row + symbols.
            if let prior = existing[scanned.relativePath], let id = prior.id {
                try store.deleteFile(id: id)
            }

            let lineCount = source.reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
            let fileID = try store.insertFile(IndexedFile(
                relativePath: scanned.relativePath, language: scanned.language,
                byteSize: scanned.byteSize, lineCount: lineCount,
                contentHash: hash, modifiedAt: scanned.modifiedAt))

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

        // Files that vanished from disk.
        for (path, prior) in existing where !seenPaths.contains(path) {
            if let id = prior.id { try store.deleteFile(id: id) }
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
