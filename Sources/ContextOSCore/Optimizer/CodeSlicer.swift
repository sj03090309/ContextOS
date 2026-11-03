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
        var dependencyCode = ""
        var omittedLocalNames = Set<String>()
    }

    struct PreparedSource {
        let source: String
        let language: Language
        let lexicon: SourceLexicon
        let parsed: ParsedFile
    }

    func prepare(source: String, language: Language) -> PreparedSource {
        let lexicon = SourceLexicon(source: source, language: language)
        let parsed = (parser as? HeuristicParser)?.parse(lexicon: lexicon, language: language)
            ?? parser.parse(source: source, language: language)
        return PreparedSource(source: source, language: language, lexicon: lexicon, parsed: parsed)
    }

    func implementationNames(_ document: PreparedSource) -> Set<String> {
        var symbols = document.parsed.symbols
        addBindings(to: &symbols, lexicon: document.lexicon, language: document.language)
        let types = symbols.filter { $0.kind == .type }
        return Set(symbols.map { qualifiedName($0, in: types) })
    }

    private func qualifiedName(_ symbol: Symbol, in types: [Symbol]) -> String {
        let owner = types.filter { $0.line < symbol.line && $0.endLine >= symbol.endLine }
            .min { $0.endLine - $0.line < $1.endLine - $1.line }
        return owner.map { $0.name + "." + symbol.name } ?? symbol.name
    }

    public func slice(source: String, language: Language, terms: [String]) -> SliceResult {
        let total = source.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        guard parser.supports(language), total >= minLinesToSlice, !terms.isEmpty else {
            return SliceResult(content: source, sliced: false, keptLines: total, totalLines: total)
        }
        return slice(prepare(source: source, language: language), terms: terms)
    }

    /// A compact retry removes optional outlines, never a selected function's
    /// body. Prepared source is reused for budget retries and merged requests.
    func slice(_ document: PreparedSource, terms: [String], exactNames: Set<String> = [],
               compact: Bool = false, collectReferences: Bool = false, includeLocalHelpers: Bool = true,
               requireAllNames: Bool = false) -> SliceResult {
        let source = document.source, language = document.language
        let lexicon = document.lexicon, parsed = document.parsed
        let lines = lexicon.lines, total = lines.count
        func whole(references: String? = nil) -> SliceResult {
            var result = SliceResult(content: source, sliced: false, keptLines: total, totalLines: total)
            if collectReferences && !lexicon.uncertain { result.dependencyCode = references ?? lexicon.codeLines.joined(separator: "\n") }
            return result
        }
        guard parser.supports(language), !lexicon.uncertain, !terms.isEmpty || !exactNames.isEmpty else { return whole() }
        guard compact || total >= minLinesToSlice || !exactNames.isEmpty else { return whole() }
        var symbols = parsed.symbols
        let typeSymbols = symbols.filter { $0.kind == .type }
        let scopedNames = exactNames.contains { $0.contains(".") }
        func matchesExact(_ symbol: Symbol) -> Bool {
            exactNames.contains(symbol.name.lowercased()) || (scopedNames && exactNames.contains(qualifiedName(symbol, in: typeSymbols).lowercased()))
        }
        var exact = exactNames.isEmpty ? [] : symbols.indices.filter { matchesExact(symbols[$0]) }
        // Imported constants and properties also have implementation bodies.
        if (exact.isEmpty || requireAllNames) && !exactNames.isEmpty {
            addBindings(to: &symbols, lexicon: lexicon, language: language)
            exact = symbols.indices.filter { matchesExact(symbols[$0]) }
        }
        let matched = exact.isEmpty ? symbols.indices.filter { Self.matches(symbols[$0], terms: terms) } : exact
        guard !matched.isEmpty else { return whole() }

        // Lines to keep: imports, every signature, and relevant bodies in full.
        var keep = Set<Int>()
        for imp in parsed.imports { keep.insert(imp.line) }
        if !compact { for sym in symbols { keep.insert(sym.line) } }
        // A matched enclosing type is structural context when the query also
        // names one of its methods. Keeping the entire type swallowed the
        // budget before the requested method could be sent.
        var selected = Set(matched.filter { index in
            let sym = symbols[index]
            return sym.kind != .type || !matched.contains { other in
                let child = symbols[other]
                return child.kind != .type && child.line > sym.line && child.line <= sym.endLine
            }
        })
        for index in selected where symbols[index].kind != .type {
            let sym = symbols[index]
            if sym.line > 0 && sym.line <= total && sym.endLine >= sym.line {
                keep.formUnion(sym.line...min(sym.endLine, total))
            }
        }
        // Common broad queries already retain most functions. Return the
        // complete source before building dependency maps we would not use.
        if !compact && Double(keep.count) > maxKeepFraction * Double(total)
            && (!collectReferences || selected.count == symbols.count) { return whole() }
        addBindings(to: &symbols, lexicon: lexicon, language: language)

        var byName: [String: [Int]] = [:]
        for (i, sym) in symbols.enumerated() { byName[sym.name, default: []].append(i) }
        let types = symbols.indices.filter { symbols[$0].kind == .type }
        func owner(_ sym: Symbol) -> Int? {
            types.filter { symbols[$0].line < sym.line && symbols[$0].endLine >= sym.endLine }
                .min { symbols[$0].endLine - symbols[$0].line < symbols[$1].endLine - symbols[$1].line }
        }
        let owners = symbols.map(owner)
        var pending = Array(selected).sorted()
        var visited = Set<Int>()
        var identifiersByLine: [Int: Set<String>] = [:]
        var dependencyLines = Set<Int>()
        var omitted = Set<String>()
        while let index = pending.popLast() {
            guard visited.insert(index).inserted else { continue }
            let sym = symbols[index]
            guard sym.line > 0 && sym.endLine >= sym.line && sym.line <= total else { continue }
            if !includeLocalHelpers && sym.kind == .type && sym.endLine - sym.line > 12 {
                // A requested large type cannot be made complete by silently
                // dropping it. Return an explicitly incomplete outline plus
                // short entry points, never truncate a method in the middle.
                keep.insert(sym.line); keep.insert(min(total, sym.endLine))
                for child in symbols where child.line > sym.line && child.endLine <= sym.endLine && child.kind != .type {
                    keep.insert(child.line)
                    if child.endLine - child.line <= 6 { keep.formUnion(child.line...min(total, child.endLine)) }
                    else { omitted.insert(qualifiedName(child, in: typeSymbols)) }
                }
                continue
            }
            var identifiers = Set<String>()
            for l in sym.line...min(sym.endLine, total) {
                // On an explicitly requested large type, discard filler
                // comments, not its implementation. Literal contents survive.
                let commentOnly = sym.kind == .type && lexicon.codeLines[l - 1].trimmingCharacters(in: .whitespaces).isEmpty
                    && !lexicon.literalLines.contains(l)
                if !commentOnly { keep.insert(l) }
                if collectReferences { dependencyLines.insert(l) }
                if let words = identifiersByLine[l] { identifiers.formUnion(words) }
                else {
                    let words = SourceLexicon.identifiers(lexicon.codeLines[l - 1])
                    identifiersByLine[l] = words; identifiers.formUnion(words)
                }
            }
            if let parent = owners[index] {
                keep.insert(symbols[parent].line); keep.insert(min(total, symbols[parent].endLine))
            }
            for name in identifiers {
                let candidates = (byName[name] ?? []).filter { $0 != index }
                let local = candidates.filter { owners[$0] == owners[index] }
                let resolved = local.isEmpty ? candidates.filter { owners[$0] == nil } : local
                for dependency in resolved where !visited.contains(dependency) {
                    // An enclosing type name in a signature must not expand
                    // back into all of its unrelated methods.
                    if symbols[dependency].kind == .type && symbols[dependency].line <= sym.line
                        && symbols[dependency].endLine >= sym.endLine { continue }
                    if !includeLocalHelpers && symbols[dependency].kind != .variable && !selected.contains(dependency) {
                        omitted.insert(qualifiedName(symbols[dependency], in: typeSymbols))
                        continue
                    }
                    if selected.insert(dependency).inserted { pending.append(dependency) }
                }
            }
        }
        // Keep the top-of-file preamble (module docstring / package line).
        for l in (compact ? [] : Array(1...min(3, total))) {
            // A short first function can put an unrelated body in lines 2–3.
            // Preamble retention must not silently pull those lines back in.
            if !parsed.symbols.contains(where: { $0.line < l && $0.endLine >= l }) { keep.insert(l) }
        }

        // Not enough elided to be worth it.
        if !compact && Double(keep.count) > maxKeepFraction * Double(total) {
            return whole(references: collectReferences ? dependencyLines.sorted().map { lexicon.codeLines[$0 - 1] }.joined(separator: "\n") : nil)
        }

        if compact {
            keep = keep.filter { !lexicon.codeLines[$0 - 1].trimmingCharacters(in: .whitespaces).isEmpty || lexicon.literalLines.contains($0) }
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

        var result = SliceResult(content: out, sliced: true, keptLines: keep.count, totalLines: total)
        result.omittedLocalNames = omitted
        if collectReferences { result.dependencyCode = dependencyLines.sorted().map { lexicon.codeLines[$0 - 1] }.joined(separator: "\n") }
        return result
    }

    private func addBindings(to symbols: inout [Symbol], lexicon: SourceLexicon, language: Language) {
        // Local bindings already live inside retained function bodies. Only
        // module/type bindings need separate dependency retention.
        var functionEnds: [Int] = []
        var declarationLines = Set(symbols.map(\.line))
        var symbolAtLine: [Int: [Symbol]] = [:]
        for sym in symbols { symbolAtLine[sym.line, default: []].append(sym) }
        for i in lexicon.lines.indices {
            functionEnds.removeAll { $0 < i + 1 }
            for sym in symbolAtLine[i + 1] ?? [] where sym.kind == .function || sym.kind == .method {
                functionEnds.append(sym.endLine)
            }
            guard functionEnds.isEmpty, !declarationLines.contains(i + 1),
                  let name = Self.bindingName(lexicon.codeLines[i], language: language) else { continue }
            symbols.append(Symbol(name: name, kind: .variable, line: i + 1, endLine: lexicon.declarationEnd(start: i)))
            declarationLines.insert(i + 1)
        }

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

    private static let swiftBinding = CompiledRegex(#"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*(?:(?:public|private(?:\(set\))?|fileprivate|internal|package|static|class|lazy|final|nonisolated\(unsafe\)|nonisolated|weak|unowned|override)\s+)*(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#)
    private static let pythonBinding = CompiledRegex(#"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?\s*="#)

    private static func bindingName(_ line: String, language: Language) -> String? {
        switch language {
        case .swift: return swiftBinding.firstCaptured(in: line)
        case .python: return pythonBinding.firstCaptured(in: line)
        case .typescript, .javascript: return HeuristicParser.boundValuePattern.firstCaptured(in: line)
        default: return nil
        }
    }

    private static func commentPrefix(for language: Language) -> String {
        switch language {
        case .python, .ruby: return "#"
        default: return "//"
        }
    }
}
