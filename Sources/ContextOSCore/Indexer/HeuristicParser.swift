import Foundation

/// A local symbol extractor using cached declaration patterns and a shared
/// lexical view for comments, literals and source ranges. It does not perform
/// type checking or provide the guarantees of a full language parser.
public struct HeuristicParser: LanguageParser {
    static let cacheRevision = "lexical-declarations-4"

    public init() {}

    public func supports(_ language: Language) -> Bool {
        switch language {
        case .swift, .python, .javascript, .typescript, .go, .rust, .java, .kotlin,
             .c, .cpp, .ruby, .objectiveC:
            return true
        case .unknown:
            return false
        }
    }

    public func parse(source: String, language: Language) -> ParsedFile {
        guard supports(language) else { return .empty }
        return parse(lexicon: SourceLexicon(source: source, language: language), language: language)
    }

    func parse(lexicon: SourceLexicon, language: Language) -> ParsedFile {
        let rules = Self.rules(for: language)
        guard !rules.isEmpty else { return .empty }

        // Work on a line array so we can look ahead to compute block ends.
        let lines = lexicon.codeLines
        var symbols: [Symbol] = []
        var imports: [ImportEdge] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lineNumber = index + 1

            if language == .javascript || language == .typescript,
               let name = Self.boundValuePattern.firstCaptured(in: line) {
                let end = lexicon.declarationEnd(start: index)
                let declaration = lines[index..<end].joined(separator: "\n")
                if declaration.contains("=>") || declaration.contains("function") {
                    symbols.append(Symbol(name: name, kind: .function, line: lineNumber, endLine: end))
                    continue
                }
            }
            if language == .swift, Self.mayContainInitializer(line),
               let name = Self.swiftInitializerPattern.firstCaptured(in: line) {
                symbols.append(Symbol(name: name, kind: .method, line: lineNumber, endLine: lexicon.blockEnd(start: index)))
                continue
            }

            for rule in rules {
                let matchLine: String
                if case .importEdge = rule.result { matchLine = lexicon.lines[index] }
                else { matchLine = line }
                guard let name = rule.pattern.firstCaptured(in: matchLine) else { continue }
                switch rule.result {
                case .symbol(let kind):
                    let end: Int
                    if language == .python {
                        end = lexicon.indentationBlockEnd(start: index)
                    } else if language == .ruby {
                        end = Self.blockEnd(lines: lines, startIndex: index, language: language)
                    } else if (language == .typescript || language == .javascript) && trimmed.hasPrefix("type ") {
                        end = lexicon.declarationEnd(start: index)
                    } else { end = lexicon.blockEnd(start: index) }
                    symbols.append(Symbol(name: name, kind: kind, line: lineNumber, endLine: end))
                case .importEdge:
                    imports.append(ImportEdge(module: name, line: lineNumber))
                }
                break // one declaration per line is enough
            }
        }

        return ParsedFile(symbols: symbols, imports: imports)
    }

    // MARK: - Block range detection

    /// The 1-based (inclusive) end line of the declaration starting at `startIndex`.
    /// Brace-matching for C-family/Swift; indentation for Python.
    static func blockEnd(lines: [String], startIndex: Int, language: Language) -> Int {
        switch language {
        case .python, .ruby:
            // Ruby's `def … end` nests by indentation in practice, so the
            // indentation heuristic reads its blocks about as well as Python's.
            return pythonBlockEnd(lines: lines, startIndex: startIndex)
        default:
            return braceBlockEnd(lines: lines, startIndex: startIndex, language: language)
        }
    }

    private static func braceBlockEnd(lines: [String], startIndex: Int, language: Language) -> Int {
        var depth = 0
        var sawBrace = false
        var quote: Character?
        var escaped = false
        var commentDepth = 0
        let limit = min(lines.count, startIndex + 4000)
        for i in startIndex..<limit {
            let characters = Array(lines[i])
            var offset = 0
            while offset < characters.count {
                let ch = characters[offset]
                let next: Character? = offset + 1 < characters.count ? characters[offset + 1] : nil
                if commentDepth > 0 {
                    if ch == "/", next == "*" { commentDepth += 1; offset += 2; continue }
                    if ch == "*", next == "/" { commentDepth -= 1; offset += 2; continue }
                    offset += 1
                    continue
                }
                if let delimiter = quote {
                    // Nested expressions inside interpolated strings need a
                    // full lexer. Preserve context when this heuristic cannot
                    // establish the boundary confidently.
                    if !escaped, language == .swift, ch == "\\", next == "(" { return lines.count }
                    if delimiter == "`", ch == "$", next == "{" { return lines.count }
                    if escaped { escaped = false }
                    else if ch == "\\" { escaped = true }
                    else if ch == delimiter { quote = nil }
                    offset += 1
                    continue
                }
                if ch == "/", next == "/" { break }
                if ch == "/", next == "*" { commentDepth = 1; offset += 2; continue }
                if language == .rust, ch == "'", let next, next.isLetter || next == "_",
                   offset + 2 >= characters.count || characters[offset + 2] != "'" {
                    offset += 1 // lifetime ('a), not a character literal ('a')
                    continue
                }
                if ch == "\"" || ch == "'" || ch == "`" {
                    quote = ch
                    offset += 1
                    continue
                }
                if ch == "{" { depth += 1; sawBrace = true }
                else if ch == "}" { depth -= 1 }
                if sawBrace && depth <= 0 { return i + 1 }
                offset += 1
            }
            escaped = false
            // Declaration with no body brace within a few lines (e.g. a protocol
            // requirement or an interface method): treat as a single line.
            if !sawBrace && i >= startIndex + 3 { break }
        }
        // An unterminated/very long block is uncertain. Preserve the remainder
        // rather than telling the slicer that only its declaration is needed.
        return sawBrace ? lines.count : startIndex + 1
    }

    private static func pythonBlockEnd(lines: [String], startIndex: Int) -> Int {
        let baseIndent = leadingSpaces(lines[startIndex])
        var end = startIndex
        var i = startIndex + 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            if leadingSpaces(line) <= baseIndent { break }
            end = i
            i += 1
        }
        return end + 1
    }

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }

    // MARK: - Rule definitions

    private enum RuleResult: Sendable {
        case symbol(SymbolKind)
        case importEdge
    }

    private struct Rule: Sendable {
        let pattern: CompiledRegex
        let result: RuleResult
    }

    // Regexes are immutable and safe to share. Recompiling them for every file
    // made both indexing and query-time slicing pay the same setup cost again.
    private static let cachedRules: [Language: [Rule]] = Dictionary(uniqueKeysWithValues:
        [Language.swift, .python, .javascript, .typescript, .go, .rust, .java,
         .kotlin, .c, .cpp, .ruby, .objectiveC, .unknown].map { ($0, makeRules(for: $0)) })

    private static func rules(for language: Language) -> [Rule] { cachedRules[language] ?? [] }

    static let boundValuePattern = rx(#"^\s*(?:(?:export|default|declare|public|private|protected|static|readonly|override|abstract)\s+)*(?:(?:const|let|var)\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:\??\s*:\s*[^=]+)?\s*="#)
    private static let swiftInitializerPattern = rx(#"^\s*(?:(?:public|private|fileprivate|internal|package|required|convenience|override|nonisolated)\s+)*(init)[?!]?\s*\("#)

    private static func mayContainInitializer(_ line: String) -> Bool {
        func contains(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard bytes.count >= 4 else { return false }
            for i in 0...(bytes.count - 4) where bytes[i] == 105 && bytes[i + 1] == 110 && bytes[i + 2] == 105 && bytes[i + 3] == 116 { return true }
            return false
        }
        if let found = line.utf8.withContiguousStorageIfAvailable(contains) { return found }
        return Array(line.utf8).withUnsafeBufferPointer(contains)
    }

    private static func makeRules(for language: Language) -> [Rule] {
        switch language {
        case .swift:
            return [
                Rule(pattern: rx(#"^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:class|struct|enum|protocol|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function))
            ]
        case .python:
            return [
                Rule(pattern: rx(#"^\s*(?:import|from)\s+([A-Za-z_][A-Za-z0-9_.]*)"#), result: .importEdge),
                Rule(pattern: rx(#"^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function))
            ]
        case .javascript, .typescript:
            return [
                Rule(pattern: rx(#"^\s*import\b.*?from\s+['""]([^'""]+)['""]"#), result: .importEdge),
                Rule(pattern: rx(#"\brequire\(\s*['""]([^'""]+)['""]\s*\)"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:class|interface|type|enum)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"\bfunction\s*\*?\s+([A-Za-z_$][A-Za-z0-9_$]*)"#), result: .symbol(.function)),
                Rule(pattern: rx(#"^\s*(?:(?:public|private|protected|static|override|abstract|async|get|set)\s+)*(?!(?:if|for|while|switch|catch|with)\b)([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;]*\)\s*(?::[^=]+)?\s*\{"#), result: .symbol(.method))
            ]
        case .go:
            return [
                Rule(pattern: rx(#"^\s*import\s+(?:\w+\s+)?['""]([^'""]+)['""]"#), result: .importEdge),
                Rule(pattern: rx(#"\btype\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"\bfunc\s+(?:\([^)]*\)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function))
            ]
        case .rust:
            return [
                Rule(pattern: rx(#"^\s*use\s+([A-Za-z_][A-Za-z0-9_:]*)"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:struct|enum|trait)\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function))
            ]
        case .java, .kotlin:
            return [
                Rule(pattern: rx(#"^\s*import\s+([A-Za-z_][A-Za-z0-9_.]*)"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:class|interface|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"\bfun\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function))
            ]
        case .c:
            return [
                Rule(pattern: rx(#"^\s*#\s*include\s*[<"]([^>"]+)[>"]"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:struct|enum|union)\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{"#), result: .symbol(.type)),
                Rule(pattern: cFunctionPattern, result: .symbol(.function))
            ]
        case .cpp:
            return [
                Rule(pattern: rx(#"^\s*#\s*include\s*[<"]([^>"]+)[>"]"#), result: .importEdge),
                Rule(pattern: rx(#"\b(?:class|struct|enum|union|namespace)\s+([A-Za-z_][A-Za-z0-9_]*)\s*[:{]"#), result: .symbol(.type)),
                Rule(pattern: cFunctionPattern, result: .symbol(.function))
            ]
        case .ruby:
            return [
                Rule(pattern: rx(#"^\s*require(?:_relative)?\s+['"]([^'"]+)['"]"#), result: .importEdge),
                Rule(pattern: rx(#"^\s*(?:class|module)\s+([A-Z][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                Rule(pattern: rx(#"^\s*def\s+(?:self\.)?([A-Za-z_][A-Za-z0-9_]*[?!=]?)"#), result: .symbol(.function))
            ]
        case .objectiveC:
            return [
                Rule(pattern: rx(#"^\s*#\s*(?:import|include)\s*[<"]([^>"]+)[>"]"#), result: .importEdge),
                Rule(pattern: rx(#"^\s*@(?:interface|implementation|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.type)),
                // Method: "- (ReturnType)name…" or "+ (ReturnType)name…".
                Rule(pattern: rx(#"^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)"#), result: .symbol(.function)),
                Rule(pattern: cFunctionPattern, result: .symbol(.function))
            ]
        case .unknown:
            return []
        }
    }

    /// C-family function *definition*: a type-ish prefix, the name, an open
    /// paren, and no ";" (which would make it a prototype). Control keywords
    /// are excluded so `if (…)` / `while (…)` don't register.
    private static let cFunctionPattern = rx(
        #"^(?!\s*(?:if|else|while|for|switch|return|do|case|sizeof)\b)[A-Za-z_][A-Za-z0-9_\s\*]*[\s\*]([A-Za-z_][A-Za-z0-9_]*)\s*\([^;]*$"#
    )

    private static func rx(_ pattern: String) -> CompiledRegex {
        CompiledRegex(pattern)
    }
}

/// Thin wrapper around `NSRegularExpression` that returns the first capture group.
struct CompiledRegex: @unchecked Sendable {
    private let regex: NSRegularExpression?

    init(_ pattern: String) {
        self.regex = try? NSRegularExpression(pattern: pattern)
    }

    func firstCaptured(in line: String) -> String? {
        guard let regex else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[captured])
    }
}
