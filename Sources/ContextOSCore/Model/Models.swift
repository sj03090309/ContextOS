import Foundation

/// A single source file recorded in the index.
public struct IndexedFile: Sendable, Equatable {
    /// SQLite rowid once persisted; nil before insertion.
    public var id: Int64?
    /// Path relative to the project root, using "/" separators.
    public var relativePath: String
    public var language: Language
    public var byteSize: Int
    public var lineCount: Int
    /// Content hash — lets later runs skip unchanged files (incremental indexing).
    public var contentHash: String
    /// File modification time (seconds since 1970).
    public var modifiedAt: Double

    public init(
        id: Int64? = nil,
        relativePath: String,
        language: Language,
        byteSize: Int,
        lineCount: Int,
        contentHash: String,
        modifiedAt: Double
    ) {
        self.id = id
        self.relativePath = relativePath
        self.language = language
        self.byteSize = byteSize
        self.lineCount = lineCount
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
    }
}

/// The kind of a declared symbol. Kept intentionally coarse for M1.
public enum SymbolKind: String, Sendable {
    case function
    case method
    case type      // class / struct / enum / protocol / interface
    case variable
}

/// A declaration found inside a file.
public struct Symbol: Sendable, Equatable {
    public var name: String
    public var kind: SymbolKind
    /// 1-based line where the declaration starts.
    public var line: Int

    public init(name: String, kind: SymbolKind, line: Int) {
        self.name = name
        self.kind = kind
        self.line = line
    }
}

/// An import / dependency edge declared in a file.
public struct ImportEdge: Sendable, Equatable {
    /// The imported module / path as written in source (unresolved in M1).
    public var module: String
    /// 1-based line of the import statement.
    public var line: Int

    public init(module: String, line: Int) {
        self.module = module
        self.line = line
    }
}

/// Everything the parser extracted from one file.
public struct ParsedFile: Sendable {
    public var symbols: [Symbol]
    public var imports: [ImportEdge]

    public init(symbols: [Symbol], imports: [ImportEdge]) {
        self.symbols = symbols
        self.imports = imports
    }

    public static let empty = ParsedFile(symbols: [], imports: [])
}

/// Summary returned after an indexing run.
public struct IndexStats: Sendable {
    public var filesIndexed: Int
    public var symbolsIndexed: Int
    public var importsIndexed: Int
    public var filesSkipped: Int
    public var byLanguage: [Language: Int]
    public var duration: TimeInterval

    public init(
        filesIndexed: Int = 0,
        symbolsIndexed: Int = 0,
        importsIndexed: Int = 0,
        filesSkipped: Int = 0,
        byLanguage: [Language: Int] = [:],
        duration: TimeInterval = 0
    ) {
        self.filesIndexed = filesIndexed
        self.symbolsIndexed = symbolsIndexed
        self.importsIndexed = importsIndexed
        self.filesSkipped = filesSkipped
        self.byLanguage = byLanguage
        self.duration = duration
    }
}
