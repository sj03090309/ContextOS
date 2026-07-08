import Foundation

/// High-level facade over indexing + optimization.
///
/// This is the single seam that both the CLI and the MCP server call, so those
/// stay thin adapters. It handles the "user configures nothing" philosophy:
/// queries auto-index the project on first use.
public struct ContextService {

    public let indexer: Indexer
    public let optimizer: ContextOptimizer
    public let git: GitAnalyzer
    /// When true, queries fold in Git recency signals automatically.
    public var useGitSignals: Bool

    public init(
        indexer: Indexer = Indexer(),
        optimizer: ContextOptimizer = ContextOptimizer(),
        git: GitAnalyzer = GitAnalyzer(),
        useGitSignals: Bool = true
    ) {
        self.indexer = indexer
        self.optimizer = optimizer
        self.git = git
        self.useGitSignals = useGitSignals
    }

    /// A lightweight snapshot of an index, for stats display.
    public struct ProjectSummary: Sendable {
        public var files: Int
        public var symbols: Int
        public var imports: Int
        public var byLanguage: [Language: Int]
        /// Estimated tokens if the *whole* project were sent as context — the
        /// baseline the optimizer saves against.
        public var estimatedTotalTokens: Int
    }

    /// Ensure `projectRoot` has an index, building one if absent.
    /// Returns `true` if it (re)built the index this call.
    @discardableResult
    public func ensureIndexed(projectRoot: URL, forceReindex: Bool = false) throws -> Bool {
        let dbURL = Indexer.databaseURL(forProjectRoot: projectRoot)
        if !forceReindex, FileManager.default.fileExists(atPath: dbURL.path) {
            return false
        }
        try indexer.index(projectRoot: projectRoot)
        return true
    }

    /// Build the index unconditionally, returning stats.
    public func reindex(projectRoot: URL) throws -> IndexStats {
        try indexer.index(projectRoot: projectRoot)
    }

    /// Rank the most relevant files for a query (auto-indexes if needed).
    public func relevantContext(
        query: String,
        projectRoot: URL,
        tokenBudget: Int
    ) throws -> ContextSelection {
        try ensureIndexed(projectRoot: projectRoot)
        let store = try Indexer.openStore(forProjectRoot: projectRoot)
        let signals = useGitSignals ? git.signals(projectRoot) : .empty
        return try optimizer.selectContext(
            query: query, from: store, tokenBudget: tokenBudget, signals: signals
        )
    }

    /// The selection plus a ready-to-send bundle of the included files' contents.
    ///
    /// This is what `read_optimized` returns: the minimal context Claude Code
    /// should actually see, already inside the token budget.
    public func optimizedBundle(
        query: String,
        projectRoot: URL,
        tokenBudget: Int
    ) throws -> (selection: ContextSelection, bundle: String) {
        let selection = try relevantContext(
            query: query, projectRoot: projectRoot, tokenBudget: tokenBudget
        )
        var bundle = ""
        for file in selection.included {
            let url = projectRoot.appendingPathComponent(file.relativePathForRead)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            bundle += "// ===== FILE: \(file.path) =====\n"
            bundle += content
            if !content.hasSuffix("\n") { bundle += "\n" }
            bundle += "\n"
        }
        return (selection, bundle)
    }

    /// Record a completed query to the local usage analytics DB. Opt-in: call
    /// this from adapters (CLI/MCP/app), never from the query path itself, so
    /// tests and internal calls don't write analytics.
    public func recordUsage(for selection: ContextSelection, query: String, projectRoot: URL) {
        let full = (try? summary(projectRoot: projectRoot))?.estimatedTotalTokens
            ?? selection.estimatedTokens
        UsageStore.record(UsageEvent(
            project: projectRoot.path,
            query: query,
            selectedTokens: selection.estimatedTokens,
            fullTokens: full,
            contextScore: selection.contextScore,
            fileCount: selection.included.count
        ))
    }

    /// Summary stats for an already-indexed project.
    public func summary(projectRoot: URL) throws -> ProjectSummary {
        let store = try Indexer.openStore(forProjectRoot: projectRoot)
        let total = try store.allFiles().reduce(0) { sum, file in
            sum + optimizer.estimator.estimate(characterCount: file.byteSize, language: file.language)
        }
        return ProjectSummary(
            files: try store.fileCount(),
            symbols: try store.symbolCount(),
            imports: try store.importCount(),
            byLanguage: try store.fileCountByLanguage(),
            estimatedTotalTokens: total
        )
    }
}

private extension ScoredFile {
    /// The stored path is already project-relative; kept as a named accessor so
    /// the read-side intent is explicit.
    var relativePathForRead: String { path }
}
