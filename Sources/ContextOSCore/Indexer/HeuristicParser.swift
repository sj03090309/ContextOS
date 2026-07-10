import Foundation

/// A pragmatic, regex/line-based symbol extractor.
///
/// It is deliberately *not* a real parser: no scopes, no accuracy guarantees.
/// The goal for M1 is a useful index that demonstrates the pipeline end-to-end.
/// A Tree-sitter backed `LanguageParser` will replace it for precise ASTs.
public struct HeuristicParser: LanguageParser {

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
        let rules = Self.rules(for: language)
        guard !rules.isEmpty else { return .empty }

        // Work on a line array so we can look ahead to compute block ends.
        let lines = source.components(separatedBy: "\n")
        var symbols: [Symbol] = []
        var imports: [ImportEdge] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let lineNumber = index + 1

            for rule in rules {
                guard let name = rule.pattern.firstCaptured(in: line) else { continue }
                switch rule.result {
                case .symbol(let kind):
                    let end = Self.blockEnd(lines: lines, startIndex: index, language: language)
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
            return braceBlockEnd(lines: lines, startIndex: startIndex)
        }
    }

    private static func braceBlockEnd(lines: [String], startIndex: Int) -> Int {
        var depth = 0
        var sawBrace = false
        let limit = min(lines.count, startIndex + 4000)
        for i in startIndex..<limit {
            for ch in lines[i] {
                if ch == "{" { depth += 1; sawBrace = true }
                else if ch == "}" { depth -= 1 }
            }
            if sawBrace && depth <= 0 { return i + 1 }
            // Declaration with no body brace within a few lines (e.g. a protocol
            // requirement or an interface method): treat as a single line.
            if !sawBrace && i >= startIndex + 3 { break }
        }
        return startIndex + 1
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

    private enum RuleResult {
        case symbol(SymbolKind)
        case importEdge
    }

    private struct Rule {
        let pattern: CompiledRegex
        let result: RuleResult
    }

    private static func rules(for language: Language) -> [Rule] {
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
                Rule(pattern: rx(#"\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)"#), result: .symbol(.function))
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
