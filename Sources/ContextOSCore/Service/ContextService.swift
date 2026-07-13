import Foundation
import CryptoKit

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

    /// Ensure `projectRoot` has a **fresh** index. Always runs the incremental
    /// indexer, which re-parses only files whose size+mtime changed since last
    /// time — cheap on an up-to-date project, and it guarantees queries never
    /// run against a stale index (the previous "skip if the DB exists" behavior
    /// meant edits were silently invisible until a manual re-index).
    @discardableResult
    public func ensureIndexed(projectRoot: URL, forceReindex: Bool = false) throws -> Bool {
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

    /// A compact, injectable context for an editor prompt hook: the relevant
    /// files with their key symbols, small enough to prepend to every prompt so
    /// the agent reads precisely instead of grepping the repo. Returns nil when
    /// nothing relevant is found. Records nothing — the caller decides.
    public func promptContext(
        query: String,
        projectRoot: URL,
        tokenBudget: Int = 2500,
        maxFiles: Int = 6
    ) throws -> (selection: ContextSelection, text: String)? {
        let selection = try relevantContext(query: query, projectRoot: projectRoot, tokenBudget: tokenBudget)
        guard !selection.included.isEmpty else { return nil }
        // Quality gate for a hook that fires on *every* prompt: only inject when
        // there's a real lexical/graph match. A selection driven purely by Git
        // recency (no term matched) means the prompt wasn't a code task — e.g. a
        // confirmation like "그렇게 해줘" — so injecting files would be noise.
        let hasLexicalMatch = selection.included.contains { file in
            file.reasons.contains { !$0.hasPrefix("git:") }
        }
        guard hasLexicalMatch else { return nil }

        let shown = Array(selection.included.prefix(maxFiles))
        let symbolsByPath = (try? Indexer.openStore(forProjectRoot: projectRoot)
            .symbols(forPaths: shown.map(\.path))) ?? [:]

        var out = "[ContextOS] 이 요청에 관련된 파일 (정확도 \(selection.contextScore)/100). "
        out += "본문이 필요하면 read_optimized(\"\(query)\") 를 호출하세요.\n"
        for file in shown {
            let reason = file.reasons.first.map { " — \($0)" } ?? ""
            out += "- \(file.path)  (~\(TokenEstimator.abbrev(file.estimatedTokens)))\(reason)\n"
            if let syms = symbolsByPath[file.path], !syms.isEmpty {
                let names = syms.prefix(6).map { "L\($0.line) \($0.name)" }.joined(separator: ", ")
                out += "    \(names)\n"
            }
        }
        if selection.included.count > maxFiles {
            out += "- … 그 외 \(selection.included.count - maxFiles)개 파일\n"
        }
        return (selection, out)
    }

    /// The selection plus a ready-to-send bundle of the included files' contents.
    ///
    /// This is what `read_optimized` returns: the minimal context the agent
    /// should actually see, already inside the token budget. Two extra token
    /// levers on top of selection + slicing:
    ///   - `memory`: bodies already delivered this session are skipped with a
    ///     one-line marker instead of resent.
    ///   - relevant-but-over-budget files are appended as a signatures-only
    ///     outline (from the index, no file reads) so the agent still sees the
    ///     surrounding structure for a handful of tokens.
    public func optimizedBundle(
        query: String,
        projectRoot: URL,
        tokenBudget: Int,
        memory: SessionMemory? = nil
    ) throws -> (selection: ContextSelection, bundle: String, skippedUnchanged: Int) {
        let selection = try relevantContext(
            query: query, projectRoot: projectRoot, tokenBudget: tokenBudget
        )
        var (bundle, skipped) = assembleBundle(selection, projectRoot: projectRoot, memory: memory)
        if !selection.excluded.isEmpty {
            bundle += signatureOutline(for: selection.excluded, projectRoot: projectRoot)
        }
        return (selection, bundle, skipped)
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
        return (selection, assembleBundle(selection, projectRoot: projectRoot, memory: nil).bundle)
    }

    /// Concatenate the included files (sliced when a query narrowed them).
    /// With a `memory`, bodies identical to ones already delivered this session
    /// are replaced by a one-line marker; returns how many were skipped.
    private func assembleBundle(
        _ selection: ContextSelection,
        projectRoot: URL,
        memory: SessionMemory?
    ) -> (bundle: String, skipped: Int) {
        var bundle = ""
        var skipped = 0
        let rootPath = projectRoot.standardizedFileURL.path
        for file in selection.included {
            let url = projectRoot.appendingPathComponent(file.path).standardizedFileURL
            // Defense in depth: never read outside the project root.
            guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { continue }
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

            if let memory {
                let hash = Self.bodyHash(body)
                if memory.isUnchanged(project: rootPath, path: file.path, bodyHash: hash) {
                    bundle += "// ===== FILE: \(file.path) — 변경 없음, 이 세션에서 이미 전달됨 (본문 생략; 다시 필요하면 fresh=true로 재요청) =====\n\n"
                    skipped += 1
                    continue
                }
                memory.markServed(project: rootPath, path: file.path, bodyHash: hash)
            }

            bundle += "// ===== FILE: \(file.path)\(note) =====\n"
            bundle += body
            if !body.hasSuffix("\n") { bundle += "\n" }
            bundle += "\n"
        }
        return (bundle, skipped)
    }

    private static func bodyHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A signatures-only outline of relevant files that didn't fit the budget,
    /// built from the index (no file reads). A few tokens buy the agent the
    /// structure of what else exists, and the line numbers to ask for it.
    private func signatureOutline(for excluded: [ScoredFile], projectRoot: URL) -> String {
        let shown = Array(excluded.prefix(5))
        guard let store = try? Indexer.openStore(forProjectRoot: projectRoot),
              // Targeted: only the shown files' symbols, not the whole table.
              let symbolsByPath = try? store.symbols(forPaths: shown.map(\.path))
        else { return "" }

        var out = "// ===== 관련도 높지만 예산 초과 — 시그니처 목차만 (필요하면 이 파일들을 지목해 다시 요청) =====\n"
        for file in shown {
            out += "// \(file.path)  (~\(TokenEstimator.abbrev(file.estimatedTokens)) tokens)\n"
            guard let symbols = symbolsByPath[file.path], !symbols.isEmpty else { continue }
            for sym in symbols.prefix(12) {
                out += "//   L\(sym.line)  \(sym.kind.rawValue) \(sym.name)\n"
            }
            if symbols.count > 12 { out += "//   … 심볼 \(symbols.count - 12)개 더\n" }
        }
        if excluded.count > 5 { out += "// … 그 외 \(excluded.count - 5)개 파일\n" }
        return out
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
