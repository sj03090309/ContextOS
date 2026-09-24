import Foundation

/// Turns free text and identifiers into comparable lowercased subword tokens.
///
/// This is what lets `"로그인 수정"` / `"fix login"` match `LoginService`,
/// `login_service.py`, and `auth/login.swift` — camelCase, snake_case, and path
/// separators are all normalized to the same subword set.
enum TextTokens {

    /// Common words that carry no selection signal (EN + a few KO imperatives).
    static let stopwords: Set<String> = [
        "the", "a", "an", "to", "of", "in", "on", "for", "and", "or", "is",
        "fix", "update", "change", "add", "remove", "make", "please", "code",
        "file", "files", "function", "method", "class", "this", "that", "with",
        "it", "its", "them", "they", "me", "my", "you", "your", "we", "our",
        "수정", "변경", "추가", "삭제", "고쳐", "고쳐줘", "해줘", "관련", "기능"
    ]

    /// Extract meaningful query terms (deduped, stopwords removed, length ≥ 2).
    static func queryTerms(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for token in subwords(of: text) where token.count >= 2 && !stopwords.contains(token) {
            if seen.insert(token).inserted { result.append(token) }
        }
        return result
    }

    /// Keep explicit file references intact instead of letting extensions such
    /// as `swift` match every source file. Also accepts quoted relative paths.
    static func fileReferences(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}_./-]+\.[\p{L}\p{N}_-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let reference = String(text[range])
            let ext = (reference as NSString).pathExtension.lowercased()
            // Dotted symbol names (e.g. SessionMemory.isUnchanged) aren't file
            // paths. Keep those terms available to ordinary symbol matching.
            guard reference.contains("/") || Language.detect(fromExtension: ext) != .unknown
                    || ["md", "txt", "json", "yaml", "yml", "toml", "xml", "html", "css", "sql", "sh"].contains(ext)
            else { return nil }
            return reference
        }
    }

    static func withoutFileReferences(_ text: String) -> String {
        fileReferences(in: text).reduce(text) { $0.replacingOccurrences(of: $1, with: " ") }
    }

    /// Split any identifier / path / phrase into lowercased subwords.
    ///
    /// `"LoginService"` → `["login", "service"]`,
    /// `"auth/jwt_helper.py"` → `["auth", "jwt", "helper", "py"]`.
    static func subwords(of text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
        }

        let characters = Array(text)
        var previous: Character? = nil
        for (index, ch) in characters.enumerated() {
            if ch.isLetter || ch.isNumber {
                // Split both loginService and HTTPClient, retaining HTTP as
                // one term instead of silently turning it into "httpclient".
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if let prev = previous, ch.isUppercase,
                   prev.isLowercase || (prev.isUppercase && nextIsLower) {
                    flush()
                }
                current.append(ch)
            } else {
                flush() // separators: space, /, _, ., -, etc.
            }
            previous = ch
        }
        flush()
        return tokens
    }
}
