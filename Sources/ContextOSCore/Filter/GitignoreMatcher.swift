import Foundation

/// Matches project-relative paths against the root `.gitignore`.
///
/// Supports the common subset of gitignore syntax: comments, blank lines,
/// `*` / `?` / `**` globs, leading-`/` (and any mid-`/`) root anchoring,
/// trailing-`/` directory-only patterns, and `!` negation with last-match-wins.
/// Nested `.gitignore` files are not consulted — the root file covers the vast
/// majority of real projects, and the built-in `FileFilter` already drops the
/// usual build/vendor trees.
public struct GitignoreMatcher: Sendable {

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
    }

    private var rules: [Rule] = []

    public var isEmpty: Bool { rules.isEmpty }

    public init(patterns: [String]) {
        for raw in patterns {
            guard let rule = Self.compile(raw) else { continue }
            rules.append(rule)
        }
    }

    /// Load the root `.gitignore` of a project, or nil if absent/empty.
    public static func load(projectRoot: URL) -> GitignoreMatcher? {
        let url = projectRoot.appendingPathComponent(".gitignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let matcher = GitignoreMatcher(patterns: text.components(separatedBy: "\n"))
        return matcher.isEmpty ? nil : matcher
    }

    /// Whether `relativePath` (project-relative, "/"-separated, no leading "/")
    /// is ignored. Directory matches imply everything beneath them, which the
    /// scanner honors by pruning matched directories wholesale.
    public func isIgnored(_ relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        let range = NSRange(relativePath.startIndex..<relativePath.endIndex, in: relativePath)
        for rule in rules {
            if rule.directoryOnly && !isDirectory { continue }
            if rule.regex.firstMatch(in: relativePath, range: range) != nil {
                ignored = !rule.negated
            }
        }
        return ignored
    }

    // MARK: - Pattern compilation

    private static func compile(_ raw: String) -> Rule? {
        var pattern = raw
        // Comments and blanks. (Escaped "\#" literals are rare; not supported.)
        if pattern.hasPrefix("#") { return nil }
        // Git strips unescaped trailing spaces.
        while pattern.hasSuffix(" ") && !pattern.hasSuffix("\\ ") { pattern.removeLast() }
        if pattern.isEmpty { return nil }

        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern.removeFirst()
        }

        var directoryOnly = false
        if pattern.hasSuffix("/") {
            directoryOnly = true
            pattern.removeLast()
        }
        if pattern.isEmpty { return nil }

        // A slash anywhere (now that the trailing one is gone) anchors the
        // pattern to the project root; otherwise it matches at any depth.
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }

        var body = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let ch = pattern[index]
            switch ch {
            case "*":
                let next = pattern.index(after: index)
                if next < pattern.endIndex, pattern[next] == "*" {
                    // "**" spans directories. Swallow an adjacent "/" so
                    // "a/**/b" also matches "a/b".
                    index = pattern.index(after: next)
                    if index < pattern.endIndex, pattern[index] == "/" {
                        body += "(?:.*/)?"
                        index = pattern.index(after: index)
                    } else {
                        body += ".*"
                    }
                    continue
                }
                body += "[^/]*"
            case "?":
                body += "[^/]"
            case "\\":
                // Escaped literal (e.g. "\ " or "\#").
                let next = pattern.index(after: index)
                if next < pattern.endIndex {
                    body += NSRegularExpression.escapedPattern(for: String(pattern[next]))
                    index = pattern.index(after: next)
                    continue
                }
            default:
                body += NSRegularExpression.escapedPattern(for: String(ch))
            }
            index = pattern.index(after: index)
        }

        let prefix = anchored ? "^" : "^(?:.*/)?"
        guard let regex = try? NSRegularExpression(pattern: prefix + body + "$") else { return nil }
        return Rule(regex: regex, negated: negated, directoryOnly: directoryOnly)
    }
}
