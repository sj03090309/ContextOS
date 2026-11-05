import Foundation

/// A transient lexical view, not an AST. Keep line positions while masking
/// comments and literal text; interpolation expressions remain visible. Both
/// declaration ranges and local dependency lookup use this same view.
struct SourceLexicon {
    let lines: [String]
    let codeLines: [String]
    let literalLines: Set<Int>
    private let literalEnds: [Int: Int]
    private let braceEnds: [Int: Int]
    private let lineOffsets: [Int]
    private let language: Language
    let uncertain: Bool

    init(source: String, language: Language, lines: [String]? = nil) {
        self.language = language
        self.lines = lines ?? source.components(separatedBy: "\n")
        var scanner = Masker(bytes: Array(source.utf8), language: language)
        scanner.code()
        codeLines = String(decoding: scanner.masked, as: UTF8.self).components(separatedBy: "\n")
        literalLines = scanner.literalLines
        literalEnds = scanner.literalEnds
        braceEnds = scanner.braceEnds
        lineOffsets = scanner.lineOffsets
        uncertain = scanner.uncertain
    }

    /// Ranges reuse brace pairs collected during the lexical pass. Looking for
    /// the first body brace ignores object types/default closures in parameters.
    func blockEnd(start: Int) -> Int {
        var parentheses = 0, brackets = 0
        var returnType = false, typeBraces = 0
        var previous: UInt8 = 0
        for i in start..<min(codeLines.count, start + 32) {
            let trimmed = codeLines[i].trimmingCharacters(in: .whitespaces)
            if i > start && parentheses == 0 && brackets == 0
                && ["func ", "def ", "function ", "class ", "struct ", "export ", "const "].contains(where: trimmed.hasPrefix) {
                return start + 1
            }
            for (column, c) in codeLines[i].utf8.enumerated() {
                if typeBraces > 0 {
                    if c == 123 { typeBraces += 1 }
                    if c == 125 { typeBraces -= 1 }
                    if typeBraces == 0 { previous = c }
                    continue
                }
                if c == 40 { parentheses += 1 }
                if c == 41 { parentheses -= 1 }
                if c == 91 { brackets += 1 }
                if c == 93 { brackets -= 1 }
                if c == 58 && parentheses == 0 && brackets == 0 { returnType = true }
                if c == 123 && parentheses == 0 && brackets == 0 {
                    // A TS object return type is part of the signature, not
                    // the function body: `helper(): { allowed: boolean } { … }`.
                    if language == .typescript && returnType && [UInt8(58),60,44,124,38].contains(previous) {
                        typeBraces = 1
                        continue
                    }
                    return braceEnds[lineOffsets[i] + column] ?? codeLines.count
                }
                if (c == 59 || c == 125) && parentheses == 0 && brackets == 0 { return start + 1 }
                if c != 32 && c != 9 { previous = c }
            }
        }
        return codeLines.count // unresolved signature/body boundary: retain it
    }

    /// Python's parameter list can close at the declaration's indentation.
    /// Establish that boundary before looking for a dedented next declaration.
    func indentationBlockEnd(start: Int) -> Int {
        func indent(_ text: String) -> Int {
            var count = 0
            for c in text.utf8 {
                if c == 32 { count += 1 }
                else if c == 9 { count += 4 }
                else { break }
            }
            return count
        }
        let base = indent(codeLines[start])
        var depth = 0, inSignature = true, end = start + 1
        for i in start..<codeLines.count {
            let line = codeLines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if i > start && !inSignature && indent(line) <= base { break }
            end = max(i + 1, end, literalEnds[i + 1] ?? 0)
            if inSignature {
                for c in line.utf8 {
                    if c == 40 || c == 91 || c == 123 { depth += 1 }
                    if c == 41 || c == 93 || c == 125 { depth -= 1 }
                }
                if depth <= 0 && line.contains(":") { inSignature = false }
            }
        }
        return inSignature ? codeLines.count : end
    }

    static func identifiers(_ text: String) -> Set<String> {
        let bytes = Array(text.utf8)
        var result = Set<String>(), start: Int?
        for i in 0...bytes.count {
            let c = i < bytes.count ? bytes[i] : 0
            let part = (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36
            if part { if start == nil { start = i } }
            else if let from = start {
                result.insert(String(decoding: bytes[from..<i], as: UTF8.self)); start = nil
            }
        }
        return result
    }

    /// Inclusive, 1-based range of a variable initializer or expression-bodied
    /// arrow. Delimiters can span lines; an incomplete declaration keeps the
    /// remainder instead of inventing an early end.
    func declarationEnd(start: Int) -> Int {
        var depth = 0
        var literalEnd = 0
        for i in start..<codeLines.count {
            literalEnd = max(literalEnd, literalEnds[i + 1] ?? 0)
            let line = codeLines[i]
            for c in line.utf8 {
                if c == 40 || c == 91 || c == 123 { depth += 1 }
                if c == 41 || c == 93 || c == 125 { depth -= 1 }
                if c == 59 && depth <= 0 { return i + 1 }
            }
            let tail = line.trimmingCharacters(in: .whitespaces)
            if depth <= 0 && literalEnd == i + 1 && tail.isEmpty { return i + 1 }
            let nextArrow = i + 1 < codeLines.count && codeLines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("=>")
            if depth <= 0 && i + 1 >= literalEnd && !nextArrow && !tail.isEmpty && !tail.hasSuffix("=") && !tail.hasSuffix("=>")
                && !tail.hasSuffix(",") && !tail.hasSuffix(".") && !tail.hasSuffix("\\")
                && !tail.hasSuffix("+") && !tail.hasSuffix("?") && !tail.hasSuffix(":") {
                return i + 1
            }
        }
        return codeLines.count
    }

    private struct Masker {
        let bytes: [UInt8]
        let language: Language
        var masked: [UInt8]
        var i = 0, line = 1
        var literalLines = Set<Int>()
        var literalEnds: [Int: Int] = [:]
        var braceEnds: [Int: Int] = [:]
        var openBraces: [Int] = []
        var lineOffsets = [0]
        var lastLiteralLine = 0
        var interpolationDepth = 0
        var uncertain = false

        init(bytes: [UInt8], language: Language) {
            self.bytes = bytes; self.masked = bytes; self.language = language
        }

        func at(_ offset: Int = 0) -> UInt8 { i + offset < bytes.count ? bytes[i + offset] : 0 }
        mutating func hide(_ count: Int = 1, literal: Bool = false) {
            for _ in 0..<count where i < bytes.count {
                if literal && line != lastLiteralLine { literalLines.insert(line); lastLiteralLine = line }
                if bytes[i] == 10 { line += 1; lineOffsets.append(i + 1) } else { masked[i] = 32 }
                i += 1
            }
        }
        mutating func advance() { if at() == 10 { line += 1; lineOffsets.append(i + 1) }; i += 1 }

        mutating func code(until terminator: UInt8? = nil) {
            if terminator != nil {
                guard interpolationDepth < 32 else {
                    uncertain = true
                    while i < bytes.count { hide() }
                    return
                }
                interpolationDepth += 1
            }
            defer { if terminator != nil { interpolationDepth -= 1 } }
            var nesting = 0
            while i < bytes.count {
                let c = at(), n = at(1)
                if let terminator, c == terminator {
                    if nesting == 0 { hide(); return }
                    nesting -= 1
                } else if (terminator == 41 && c == 40) || (terminator == 125 && c == 123) { nesting += 1 }
                if c == 47 && n == 47 && language != .python && language != .ruby {
                    while i < bytes.count && at() != 10 { hide() }
                } else if c == 47 && n == 42 && language != .python && language != .ruby {
                    hide(2); var depth = 1
                    while i < bytes.count && depth > 0 {
                        if at() == 47 && at(1) == 42 { depth += 1; hide(2) }
                        else if at() == 42 && at(1) == 47 { depth -= 1; hide(2) }
                        else { hide() }
                    }
                    if depth > 0 { uncertain = true }
                } else if c == 35 && (language == .python || language == .ruby) {
                    while i < bytes.count && at() != 10 { hide() }
                } else if c == 35 && language == .swift {
                    var hashes = 0
                    while at(hashes) == 35 { hashes += 1 }
                    if at(hashes) == 34 { hide(hashes, literal: true); string(34, hashes: hashes) }
                    else { advance() }
                } else if c == 34 || c == 39 || c == 96 {
                    // Rust lifetimes are identifiers, not character literals.
                    if language == .rust && c == 39 && at(2) != 39 && ((65...90).contains(n) || (97...122).contains(n) || n == 95) {
                        advance()
                    } else { string(c) }
                } else if c == 47 && (language == .javascript || language == .typescript) && startsRegex() {
                    regex()
                } else {
                    if c == 123 { openBraces.append(i) }
                    if c == 125, let open = openBraces.popLast() { braceEnds[open] = line }
                    advance()
                }
            }
            if terminator != nil { uncertain = true }
        }

        func startsRegex() -> Bool {
            var p = i - 1
            while p >= 0 && (bytes[p] == 32 || bytes[p] == 9 || bytes[p] == 10 || bytes[p] == 13) { p -= 1 }
            if p < 0 { return true }
            if [UInt8(61),40,91,123,58,44,33,63,59,38,124].contains(bytes[p]) { return true }
            if bytes[p] == 62 && p > 0 && bytes[p - 1] == 61 { return true } // arrow expression
            // `return /.../` is common; division after an identifier is not.
            let start = max(0, p - 5)
            return String(decoding: bytes[start...p], as: UTF8.self) == "return"
        }

        mutating func regex() {
            let start = i, firstLine = line
            defer { literalEnds[firstLine] = max(literalEnds[firstLine] ?? 0, line) }
            hide(literal: true); masked[start] = 48; var bracket = false
            while i < bytes.count {
                if at() == 92 { hide(2, literal: true); continue }
                if at() == 91 { bracket = true }
                if at() == 93 { bracket = false }
                if at() == 47 && !bracket { hide(literal: true); return }
                if at() == 10 { uncertain = true; return }
                hide(literal: true)
            }
            uncertain = true
        }

        mutating func string(_ quote: UInt8, hashes: Int = 0) {
            let start = i, firstLine = line
            defer { literalEnds[firstLine] = max(literalEnds[firstLine] ?? 0, line) }
            var prefixStart = i
            if language == .python {
                while prefixStart > 0 && ((65...90).contains(bytes[prefixStart - 1]) || (97...122).contains(bytes[prefixStart - 1])) { prefixStart -= 1 }
            }
            let prefix = String(decoding: bytes[prefixStart..<i], as: UTF8.self).lowercased()
            let pythonInterpolation = language == .python && ["f", "fr", "rf"].contains(prefix)
            let triple = quote != 96 && at(1) == quote && at(2) == quote
            let width = triple ? 3 : 1
            hide(width, literal: true)
            masked[start] = 48 // an opaque value, not an unfinished `name =`
            while i < bytes.count {
                if at() == quote && (!triple || (at(1) == quote && at(2) == quote)) {
                    var endMatches = true
                    for h in 0..<hashes where at(width + h) != 35 { endMatches = false }
                    if endMatches { hide(width + hashes, literal: true); return }
                }
                if at() == 92 {
                    var marker = 1
                    while marker <= hashes && at(marker) == 35 { marker += 1 }
                    if marker == hashes + 1 && at(marker) == 40 && language == .swift {
                        hide(marker + 1, literal: true); code(until: 41); continue
                    }
                    if hashes == 0 { hide(2, literal: true); continue }
                }
                if quote == 96 && at() == 36 && at(1) == 123 {
                    hide(2, literal: true); code(until: 125); continue
                }
                if pythonInterpolation && at() == 123 {
                    if at(1) == 123 { hide(2, literal: true) }
                    else { hide(literal: true); code(until: 125) }
                    continue
                }
                hide(literal: true)
            }
            uncertain = true
        }
    }
}
