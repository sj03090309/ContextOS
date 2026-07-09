import Foundation

/// High-level facade over indexing + optimization.
///
/// This is the single seam that both the CLI and the MCP server call, so those
/// stay thin adapters. It handles the "user configures nothing" philosophy:
/// queries auto-index the project on first use.
public struct ContextService: Sendable {

    public let indexer: Indexer
    public let optimizer: ContextOptimizer
    public let git: GitAnalyzer
    public let slicer: CodeSlicer
    public let refiner: QueryRefiner
    /// When true, queries fold in Git recency signals automatically.
    public var useGitSignals: Bool
    /// When true, `optimizedBundle` slices files to only the relevant symbols.
    public var useSlicing: Bool
    /// When true, queries are actively refined (dictionary/typo/index) first.
    public var useRefiner: Bool

    public init(
        indexer: Indexer = Indexer(),
        optimizer: ContextOptimizer = ContextOptimizer(),
        git: GitAnalyzer = GitAnalyzer(),
        slicer: CodeSlicer = CodeSlicer(),
        refiner: QueryRefiner = QueryRefiner(),
        useGitSignals: Bool = true,
        useSlicing: Bool = true,
        useRefiner: Bool = true
    ) {
        self.indexer = indexer
        self.optimizer = optimizer
        self.git = git
        self.slicer = slicer
        self.refiner = refiner
        self.useGitSignals = useGitSignals
        self.useSlicing = useSlicing
        self.useRefiner = useRefiner
    }

    /// Actively refine a raw query against a project's symbol vocabulary.
    public func refineQuery(_ query: String, projectRoot: URL) -> RefinedQuery {
        let vocab = (try? Indexer.openStore(forProjectRoot: projectRoot).symbolNames()) ?? []
        return refiner.refine(query, vocabulary: vocab)
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

        let refined = useRefiner ? refiner.refine(query, vocabulary: (try? store.symbolNames()) ?? []) : nil
        var selection = try optimizer.selectContext(
            query: query, from: store, tokenBudget: tokenBudget,
            signals: signals, overrideTerms: refined?.terms
        )
        selection.refinement = refined
        return selection
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
        return (selection, assembleBundle(selection, projectRoot: projectRoot))
    }

    /// Proactively build context from the files you're **currently editing**
    /// (uncommitted Git changes) — no query needed. Returns nil if the working
    /// tree is clean. This powers the "we prepared context for you" experience.
    public func proactiveContext(
        projectRoot: URL,
        tokenBudget: Int = 8000
    ) throws -> (selection: ContextSelection, bundle: String)? {
        let signals = git.signals(projectRoot)
        guard !signals.changedPaths.isEmpty else { return nil }
        try ensureIndexed(projectRoot: projectRoot)
        let store = try Indexer.openStore(forProjectRoot: projectRoot)
        let selection = try optimizer.selectContext(
            query: "", from: store, tokenBudget: tokenBudget, signals: signals
        )
        guard !selection.included.isEmpty else { return nil }
        return (selection, assembleBundle(selection, projectRoot: projectRoot))
    }

    /// Concatenate the included files (sliced when a query narrowed them).
    private func assembleBundle(_ selection: ContextSelection, projectRoot: URL) -> String {
        var bundle = ""
        for file in selection.included {
            let url = projectRoot.appendingPathComponent(file.path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var body = content
            var note = ""
            if useSlicing, !selection.terms.isEmpty {
                let result = slicer.slice(source: content, language: file.language, terms: selection.terms)
                if result.sliced {
                    body = result.content
                    note = "  (\(result.totalLines)줄 중 \(result.keptLines)줄, 관련 심볼만)"
                }
            }
            bundle += "// ===== FILE: \(file.path)\(note) =====\n"
            bundle += body
            if !body.hasSuffix("\n") { bundle += "\n" }
            bundle += "\n"
        }
        return bundle
    }

    /// Record a completed optimization to the local savings DB, so the menu-bar
    /// dashboard can show how many tokens were saved. Called by the MCP server
    /// each time Claude Code asks for context.
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
