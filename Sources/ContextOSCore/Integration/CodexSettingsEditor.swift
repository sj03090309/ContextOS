import Foundation

/// Narrow, lossless TOML edits: only command/args inside one ContextOS table.
/// Complex target values and ambiguous/duplicate tables fail closed.
struct CodexSettingsEditor {
    var text: String
    let file = "config.toml"
    private let begin = "# ContextOS:begin"
    private let end = "# ContextOS:end"

    init(_ data: Data?) throws {
        text = try SettingsTransaction.text(data, file: "config.toml")
        _ = try section()
    }

    var data: Data { Data(text.utf8) }
    var hasSection: Bool { get throws { try section() != nil } }

    func ownedSection() throws -> String? {
        guard let section = try section(), section.marked else { return nil }
        return text.substring(lines: section.range)
    }

    func value(_ key: String) throws -> String? {
        guard let section = try section() else { return nil }
        let lines = text.components(separatedBy: "\n")
        let matches = try keyLines(key, in: section)
        guard let index = matches.first else { return nil }
        let line = lines[index]
        let content = Self.withoutComment(line)
        guard let equal = content.firstIndex(of: "=") else { throw SettingsSafetyError.invalid(file) }
        let value = String(content[content.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
        if key == "command" {
            let valid = (try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)) is String
                || (value.hasPrefix("'") && value.hasSuffix("'") && !value.hasPrefix("'''"))
            guard valid, !value.hasPrefix("\"\"\"") else { throw SettingsSafetyError.invalid(file) }
        } else {
            // Preserve unknown TOML shapes; do not guess where a multiline value ends.
            guard value.hasPrefix("["), value.hasSuffix("]"), !value.contains("\n") else {
                throw SettingsSafetyError.invalid(file)
            }
        }
        return value
    }

    mutating func set(_ key: String, to value: String?) throws {
        guard let section = try section() else { throw SettingsSafetyError.invalid(file) }
        var lines = text.components(separatedBy: "\n")
        let matches = try keyLines(key, in: section)
        if let index = matches.first {
            _ = try self.value(key)
            let line = lines[index]
            guard let equal = line.firstIndex(of: "=") else { throw SettingsSafetyError.invalid(file) }
            if let value {
                let code = Self.withoutComment(line)
                let comment = String(line.dropFirst(code.count))
                lines[index] = String(line[...equal]) + " " + value + (comment.isEmpty ? "" : " " + comment)
            } else { lines.remove(at: index) }
        } else if let value {
            lines.insert("\(key) = \(value)", at: section.header + 1)
        }
        text = lines.joined(separator: "\n")
        _ = try self.section()
    }

    mutating func addSection(command: String) throws {
        guard try section() == nil else { throw SettingsSafetyError.invalid(file) }
        let encoded = String(data: try JSONSettingsEditor.encode(command), encoding: .utf8)!
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "\(begin)\n[mcp_servers.contextos]\ncommand = \(encoded)\nargs = []\n\(end)\n"
    }

    mutating func removeOwnedSection(expected: String) throws {
        guard let section = try section(), section.marked,
              text.substring(lines: section.range) == expected else { throw SettingsSafetyError.conflict(file) }
        var lines = text.components(separatedBy: "\n")
        lines.removeSubrange(section.range)
        text = lines.joined(separator: "\n")
    }

    private struct Section { var header: Int; var range: Range<Int>; var marked: Bool }
    private func section() throws -> Section? {
        let lines = text.components(separatedBy: "\n")
        var headers: [(Int, [String])] = []
        var multiline: String?
        var beginLines: [Int] = [], endLines: [Int] = []
        for (index, line) in lines.enumerated() {
            if multiline == nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == begin { beginLines.append(index) }
                if trimmed == end { endLines.append(index) }
                let code = Self.withoutComment(line).trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("["), !code.hasPrefix("[[") {
                    guard code.hasSuffix("]") else { throw SettingsSafetyError.invalid(file) }
                    let inner = String(code.dropFirst().dropLast())
                    headers.append((index, try Self.headerPath(inner)))
                }
            }
            // Triple quoted values can contain fake table headers or markers.
            let bytes = Array(line.utf8)
            var i = 0
            var quote: UInt8?
            while i < bytes.count {
                if let active = multiline {
                    let delimiter = Array(active.utf8)
                    if i + 3 <= bytes.count, Array(bytes[i..<i+3]) == delimiter {
                        multiline = nil; i += 3; continue
                    }
                    if active == "\"\"\"", bytes[i] == 92 { i += 2 } else { i += 1 }
                } else if let q = quote {
                    if q == 34, bytes[i] == 92 { i += 2; continue }
                    if bytes[i] == q { quote = nil }; i += 1
                } else {
                    if bytes[i] == 35 { break }
                    if i + 3 <= bytes.count, bytes[i] == 34 || bytes[i] == 39,
                       bytes[i + 1] == bytes[i], bytes[i + 2] == bytes[i] {
                        multiline = String(repeating: bytes[i] == 34 ? "\"" : "'", count: 3); i += 3
                    } else {
                        if bytes[i] == 34 || bytes[i] == 39 { quote = bytes[i] }
                        i += 1
                    }
                }
            }
        }
        guard multiline == nil, beginLines.count == endLines.count, beginLines.count <= 1 else {
            throw SettingsSafetyError.invalid(file)
        }
        let targets = headers.filter { $0.1 == ["mcp_servers", "contextos"] }
        guard targets.count <= 1 else { throw SettingsSafetyError.invalid(file) }
        guard let target = targets.first else {
            guard beginLines.isEmpty else { throw SettingsSafetyError.invalid(file) }
            // An implicit ContextOS parent with child tables would become an
            // ambiguous registration. Ask for a valid parent rather than append.
            guard !headers.contains(where: { $0.1.starts(with: ["mcp_servers", "contextos"]) }) else {
                throw SettingsSafetyError.invalid(file)
            }
            return nil
        }
        let next = headers.first(where: { $0.0 > target.0 })?.0 ?? lines.count - (text.hasSuffix("\n") ? 1 : 0)
        if let first = beginLines.first, let last = endLines.first {
            guard first < target.0, last >= target.0, last < next,
                  headers.filter({ first < $0.0 && $0.0 <= last }).count == 1 else {
                throw SettingsSafetyError.invalid(file)
            }
            return Section(header: target.0, range: first..<last + 1, marked: true)
        }
        return Section(header: target.0, range: target.0..<next, marked: false)
    }

    private func keyLines(_ key: String, in section: Section) throws -> [Int] {
        let lines = text.components(separatedBy: "\n")
        let pattern = "^\\s*(?:\(key)|\"\(key)\"|'\(key)')\\s*="
        let found = (section.header + 1..<section.range.upperBound).filter {
            Self.withoutComment(lines[$0]).range(of: pattern, options: .regularExpression) != nil
        }
        guard found.count <= 1 else { throw SettingsSafetyError.invalid(file) }
        return found
    }

    private static func headerPath(_ text: String) throws -> [String] {
        var parts: [String] = [], current = "", quote: Character?
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" { quote = c }
            else if c == "." { parts.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(c) }
        }
        guard quote == nil else { throw SettingsSafetyError.invalid("config.toml") }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        guard parts.allSatisfy({ !$0.isEmpty && !$0.contains("\\") }) else { throw SettingsSafetyError.invalid("config.toml") }
        return parts
    }

    private static func withoutComment(_ text: String) -> String {
        var quote: Character?, escaped = false
        for index in text.indices {
            let c = text[index]
            if escaped { escaped = false; continue }
            if let q = quote {
                if q == "\"", c == "\\" { escaped = true }
                else if c == q { quote = nil }
            } else if c == "#" { return String(text[..<index]) }
            else if c == "\"" || c == "'" { quote = c }
        }
        return text
    }
}

private extension String {
    func substring(lines: Range<Int>) -> String {
        components(separatedBy: "\n")[lines].joined(separator: "\n")
    }
}
