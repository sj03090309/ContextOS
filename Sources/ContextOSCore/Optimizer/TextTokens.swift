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

        var previous: Character? = nil
        for ch in text {
            if ch.isLetter || ch.isNumber {
                // camelCase / PascalCase boundary: lower→Upper.
                if let prev = previous, prev.isLowercase, ch.isUppercase {
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
