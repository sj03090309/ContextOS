import Foundation

/// Selects the minimal, most-relevant set of files for a query — the core of
/// ContextOS's token savings. Entirely rule-based (no AI):
///
///   1. Lexical scoring: query terms vs symbol names, file names, paths, imports.
///   2. Import-graph expansion: strong hits pull in their neighbours, with decay
///      (this is how "login" reaches auth → jwt → database).
///   3. Greedy selection within a token budget, surfacing what didn't fit.
public struct ContextOptimizer: Sendable {

    public var estimator: TokenEstimator
    /// How many import-graph hops to expand from a matched file.
    public var maxHops: Int
    /// Score multiplier applied per hop during expansion (0–1).
    public var linkDecay: Double

    public init(
        estimator: TokenEstimator = TokenEstimator(),
        maxHops: Int = 2,
        linkDecay: Double = 0.4
    ) {
        self.estimator = estimator
        self.maxHops = maxHops
        self.linkDecay = linkDecay
    }

    // Per-term score by strongest category it matched.
    private static let symbolExactScore = 5.0
    private static let symbolPartialScore = 3.0
    private static let fileNameScore = 3.0
    private static let pathScore = 2.0
    private static let importScore = 1.0
    // Git recency boosts (Smart Context Builder): actively-edited files rise.
    private static let gitChangedBoost = 3.0
    private static let gitRecentBoost = 1.5

    public func selectContext(
        query: String,
        from store: IndexStore,
        tokenBudget: Int,
        signals: GitSignals = .empty,
        overrideTerms: [String]? = nil
    ) throws -> ContextSelection {
        // Use actively-refined terms when provided, else derive from the query.
        let terms = overrideTerms ?? TextTokens.queryTerms(query)
        let files = try store.allFiles()
        let symbolsByFile = try store.symbolsByFile()
        let importsByFile = try store.importsByFile()

        // Proceed if there's *any* signal: query terms or Git recency.
        guard !files.isEmpty, !terms.isEmpty || !signals.isEmpty else {
            return ContextSelection(
                query: query, terms: terms, included: [], excluded: [],
                tokenBudget: tokenBudget, estimatedTokens: 0, contextScore: 0
            )
        }

        var byID: [Int64: IndexedFile] = [:]
        for f in files { if let id = f.id { byID[id] = f } }

        // 1. Base lexical scoring.
        var scores: [Int64: Double] = [:]
        var reasons: [Int64: [String]] = [:]

        for file in files {
            guard let id = file.id else { continue }
            let fileStem = PathResolution.stem(of: file.relativePath)
            let pathWords = Set(TextTokens.subwords(of: file.relativePath))
            let symbols = symbolsByFile[id] ?? []
            let importWords = Set((importsByFile[id] ?? []).flatMap { TextTokens.subwords(of: $0.module) })

            var fileScore = 0.0
            var fileReasons: [String] = []

            for term in terms {
                var best = 0.0
                var reason: String? = nil

                // Symbol matches (strongest signal).
                for symbol in symbols {
                    let words = TextTokens.subwords(of: symbol.name)
                    if words.contains(term) {
                        if Self.symbolExactScore > best {
                            best = Self.symbolExactScore
                            reason = "symbol \(symbol.name)"
                        }
                    } else if term.count >= 3, words.contains(where: { $0.contains(term) }) {
                        if Self.symbolPartialScore > best {
                            best = Self.symbolPartialScore
                            reason = "symbol ~\(symbol.name)"
                        }
                    }
                }

                // File name.
                if TextTokens.subwords(of: fileStem).contains(term), Self.fileNameScore > best {
                    best = Self.fileNameScore
                    reason = "filename \(fileStem)"
                }
                // Path component.
                if best < Self.pathScore, pathWords.contains(term) {
                    best = Self.pathScore
                    reason = "path"
                }
                // Import module.
                if best < Self.importScore, importWords.contains(term) {
                    best = Self.importScore
                    reason = "import \(term)"
                }

                if best > 0 {
                    fileScore += best
                    if let reason { fileReasons.append("‘\(term)’ → \(reason)") }
                }
            }

            if fileScore > 0 {
                scores[id] = fileScore
                reasons[id] = fileReasons
            }
        }

        // 1b. Git recency: files you're editing (or recently committed) rise, and
        // become seeds for graph expansion below — the "Smart Context Builder".
        if !signals.isEmpty {
            var idByPath: [String: Int64] = [:]
            for f in files { if let id = f.id { idByPath[f.relativePath] = id } }
            for path in signals.changedPaths {
                if let id = idByPath[path] {
                    scores[id, default: 0] += Self.gitChangedBoost
                    reasons[id, default: []].append("git: 커밋 안 된 변경")
                }
            }
            for path in signals.recentPaths {
                if let id = idByPath[path] {
                    scores[id, default: 0] += Self.gitRecentBoost
                    reasons[id, default: []].append("git: 최근 수정됨")
                }
            }
        }

        // 2. Import-graph expansion from the seed hits.
        let adjacency = buildAdjacency(files: files, importsByFile: importsByFile)
        let seeds = scores // snapshot before propagation
        for (seed, base) in seeds {
            var visited: Set<Int64> = [seed]
            var frontier: [Int64] = [seed]
            var hop = 1
            while hop <= maxHops, !frontier.isEmpty {
                var next: [Int64] = []
                let boost = base * pow(linkDecay, Double(hop))
                for node in frontier {
                    for neighbour in adjacency[node] ?? [] where !visited.contains(neighbour) {
                        visited.insert(neighbour)
                        next.append(neighbour)
                        scores[neighbour, default: 0] += boost
                        let seedPath = byID[seed]?.relativePath ?? "?"
                        reasons[neighbour, default: []].append("linked via \(seedPath)")
                    }
                }
                frontier = next
                hop += 1
            }
        }

        // 3. Rank + greedily fill the budget.
        let candidates: [ScoredFile] = scores.compactMap { id, score in
            guard let file = byID[id] else { return nil }
            let tokens = estimator.estimate(characterCount: file.byteSize, language: file.language)
            return ScoredFile(
                path: file.relativePath,
                language: file.language,
                score: (score * 100).rounded() / 100,
                estimatedTokens: tokens,
                reasons: dedupe(reasons[id] ?? [])
            )
        }
        .sorted { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.estimatedTokens < rhs.estimatedTokens
        }

        var included: [ScoredFile] = []
        var excluded: [ScoredFile] = []
        var runningTokens = 0
        for candidate in candidates {
            if runningTokens + candidate.estimatedTokens <= tokenBudget {
                included.append(candidate)
                runningTokens += candidate.estimatedTokens
            } else {
                excluded.append(candidate)
            }
        }

        return ContextSelection(
            query: query,
            terms: terms,
            included: included,
            excluded: excluded,
            tokenBudget: tokenBudget,
            estimatedTokens: runningTokens,
            contextScore: Self.contextScore(included: included, excluded: excluded)
        )
    }

    // MARK: - Import graph

    /// Undirected adjacency from resolved import edges. Modules resolve to files
    /// by matching their last path/dot component against file name stems.
    private func buildAdjacency(
        files: [IndexedFile],
        importsByFile: [Int64: [ImportEdge]]
    ) -> [Int64: Set<Int64>] {
        var stemToIDs: [String: [Int64]] = [:]
        for file in files {
            guard let id = file.id else { continue }
            stemToIDs[PathResolution.stem(of: file.relativePath).lowercased(), default: []].append(id)
        }

        var adjacency: [Int64: Set<Int64>] = [:]
        for file in files {
            guard let id = file.id else { continue }
            for edge in importsByFile[id] ?? [] {
                let stem = PathResolution.moduleStem(edge.module)
                for target in stemToIDs[stem] ?? [] where target != id {
                    adjacency[id, default: []].insert(target)
                    adjacency[target, default: []].insert(id)
                }
            }
        }
        return adjacency
    }

    // MARK: - Context score (0–100)

    private static func contextScore(included: [ScoredFile], excluded: [ScoredFile]) -> Int {
        guard let top = included.first else { return 0 }
        let includedMass = included.reduce(0) { $0 + $1.score }
        let excludedMass = excluded.reduce(0) { $0 + $1.score }
        let totalMass = includedMass + excludedMass
        // Coverage: did the relevant mass fit the budget?
        let coverage = totalMass > 0 ? includedMass / totalMass : 1
        // Concentration: is the top hit a strong, confident match?
        let concentration = min(1, top.score / symbolExactScore)
        return Int((100 * (0.6 * coverage + 0.4 * concentration)).rounded())
    }

    // MARK: - Helpers

    private func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
