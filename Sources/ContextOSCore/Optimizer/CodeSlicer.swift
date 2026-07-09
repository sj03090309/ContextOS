import Foundation

/// Reduces a file to only what a query needs: imports + every symbol's signature
/// (a "table of contents") + the full body of the symbols the query matches.
/// Everything else is elided with a marker.
///
/// This is the core token-saving lever: instead of a whole 500-line file, Claude
/// Code receives the 40 lines that matter plus the structure to orient itself.
public struct CodeSlicer: Sendable {

    public var parser: LanguageParser
    /// Files shorter than this are sent whole (slicing isn't worth it).
    public var minLinesToSlice: Int
    /// If slicing keeps more than this fraction of lines, send the whole file.
    public var maxKeepFraction: Double

    public init(
        parser: LanguageParser = HeuristicParser(),
        minLinesToSlice: Int = 40,
        maxKeepFraction: Double = 0.75
    ) {
        self.parser = parser
        self.minLinesToSlice = minLinesToSlice
        self.maxKeepFraction = maxKeepFraction
    }

    public struct SliceResult: Sendable {
        public var content: String
        public var sliced: Bool
        public var keptLines: Int
        public var totalLines: Int
    }

    public func slice(source: String, language: Language, terms: [String]) -> SliceResult {
        let lines = source.components(separatedBy: "\n")
        let total = lines.count

        // Bail out to the whole file when slicing can't help.
        guard parser.supports(language), total >= minLinesToSlice, !terms.isEmpty else {
            return SliceResult(content: source, sliced: false, keptLines: total, totalLines: total)
        }

        let parsed = parser.parse(source: source, language: language)
        let relevant = parsed.symbols.filter { Self.matches($0, terms: terms) }
        guard !relevant.isEmpty else {
            return SliceResult(content: source, sliced: false, keptLines: total, totalLines: total)
        }

        // Lines to keep: imports, every signature, and relevant bodies in full.
        var keep = Set<Int>()
        for imp in parsed.imports { keep.insert(imp.line) }
        for sym in parsed.symbols { keep.insert(sym.line) }
        for sym in relevant where sym.endLine >= sym.line {
            for l in sym.line...min(sym.endLine, total) { keep.insert(l) }
        }
        // Keep the top-of-file preamble (module docstring / package line).
        for l in 1...min(3, total) { keep.insert(l) }

        // Not enough elided to be worth it.
        if Double(keep.count) > maxKeepFraction * Double(total) {
            return SliceResult(content: source, sliced: false, keptLines: total, totalLines: total)
        }

        let marker = Self.commentPrefix(for: language)
        var out = ""
        var elided = 0
        for (i, line) in lines.enumerated() {
            let n = i + 1
            if keep.contains(n) {
                if elided > 0 { out += "\(marker) … (\(elided)줄 생략)\n"; elided = 0 }
                out += line + "\n"
            } else {
                elided += 1
            }
        }
        if elided > 0 { out += "\(marker) … (\(elided)줄 생략)\n" }

        return SliceResult(content: out, sliced: true, keptLines: keep.count, totalLines: total)
    }

    // MARK: - Helpers

    static func matches(_ symbol: Symbol, terms: [String]) -> Bool {
        let words = TextTokens.subwords(of: symbol.name)
        for term in terms {
            if words.contains(term) { return true }
            if term.count >= 3, words.contains(where: { $0.contains(term) }) { return true }
        }
        return false
    }

    private static func commentPrefix(for language: Language) -> String {
        switch language {
        case .python, .ruby: return "#"
        default: return "//"
        }
    }
}
