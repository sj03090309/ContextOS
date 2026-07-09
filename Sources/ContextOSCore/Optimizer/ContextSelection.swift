import Foundation

/// One file the optimizer scored for a query.
public struct ScoredFile: Sendable, Equatable {
    public var path: String
    public var language: Language
    public var score: Double
    public var estimatedTokens: Int
    /// Human-readable reasons this file was chosen (for Context Preview).
    public var reasons: [String]

    public init(path: String, language: Language, score: Double, estimatedTokens: Int, reasons: [String]) {
        self.path = path
        self.language = language
        self.score = score
        self.estimatedTokens = estimatedTokens
        self.reasons = reasons
    }
}

/// The optimizer's answer to "what context should Claude Code see for this query?"
public struct ContextSelection: Sendable {
    public var query: String
    public var terms: [String]
    /// Files that fit the budget, most relevant first.
    public var included: [ScoredFile]
    /// Relevant files that did NOT fit the token budget (surfaced, not silently dropped).
    public var excluded: [ScoredFile]
    public var tokenBudget: Int
    /// Sum of estimated tokens across `included`.
    public var estimatedTokens: Int
    /// 0–100 quality score for the resulting context.
    public var contextScore: Int
    /// How the raw query was actively refined (dictionary/typo/index), if at all.
    public var refinement: RefinedQuery? = nil

    public var isEmpty: Bool { included.isEmpty && excluded.isEmpty }
}
