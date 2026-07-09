import Foundation

/// The result of actively refining a raw query into project-grounded terms.
public struct RefinedQuery: Sendable, Equatable {
    public var original: String
    /// Final terms used for matching (corrected + expanded).
    public var terms: [String]
    /// Typo fixes applied against the project's symbol vocabulary.
    public var corrections: [Correction]
    /// Dictionary / synonym expansions applied.
    public var expansions: [Expansion]

    public struct Correction: Sendable, Equatable { public var from: String; public var to: String }
    public struct Expansion: Sendable, Equatable { public var from: String; public var to: [String] }

    public var changed: Bool { !corrections.isEmpty || !expansions.isEmpty }

    /// A human-readable "here's how I understood it" line.
    public var explanation: String {
        var parts: [String] = []
        for e in expansions { parts.append("\(e.from) → \(e.to.joined(separator: ", "))") }
        for c in corrections { parts.append("오타 교정: \(c.from) → \(c.to)") }
        return parts.joined(separator: " · ")
    }
}

/// Actively rewrites a rough query into better matching terms — **without any
/// AI**. Three local rule engines: a Korean↔English dev-term dictionary, typo
/// correction against the project's own symbols (edit distance), and grounding
/// in the index vocabulary. The output differs per project, so it never feels
/// like canned advice.
public struct QueryRefiner: Sendable {

    public init() {}

    public func refine(_ query: String, vocabulary: [String]) -> RefinedQuery {
        let base = TextTokens.queryTerms(query)
        let vocabWords = Set(vocabulary.flatMap { TextTokens.subwords(of: $0) }.filter { $0.count >= 3 })

        var terms: [String] = []
        var seen = Set<String>()
        var corrections: [RefinedQuery.Correction] = []
        var expansions: [RefinedQuery.Expansion] = []

        func add(_ t: String) { if seen.insert(t).inserted { terms.append(t) } }

        for term in base {
            // 1. Dictionary / synonym expansion (Korean → English, EN synonyms).
            if let mapped = Self.dictionary[term] {
                expansions.append(.init(from: term, to: mapped))
                for m in mapped { add(m) }
                if term.allSatisfy(\.isASCII) { add(term) } // keep the English original too
                continue
            }
            // 2. Typo correction against the project's real symbols.
            if !vocabWords.contains(term), let fix = Self.closest(term, in: vocabWords) {
                corrections.append(.init(from: term, to: fix))
                add(fix)
                continue
            }
            // 3. Keep as typed.
            add(term)
        }

        return RefinedQuery(original: query, terms: terms, corrections: corrections, expansions: expansions)
    }

    // MARK: - Bilingual dev-term dictionary (local, curated)

    static let dictionary: [String: [String]] = [
        // Korean → English
        "로그인": ["login", "signin", "auth"],
        "로그아웃": ["logout", "signout"],
        "인증": ["auth", "authenticate", "authentication"],
        "회원가입": ["signup", "register"],
        "가입": ["signup", "register"],
        "결제": ["payment", "billing", "charge", "checkout"],
        "비밀번호": ["password"],
        "암호": ["password", "encrypt"],
        "사용자": ["user", "account"],
        "계정": ["account", "user"],
        "토큰": ["token", "jwt"],
        "세션": ["session"],
        "데이터베이스": ["database"],
        "설정": ["config", "settings", "setup"],
        "오류": ["error", "exception"],
        "에러": ["error", "exception"],
        "검색": ["search", "query", "find"],
        "지갑": ["wallet"],
        "거래": ["transaction", "trade"],
        "잔액": ["balance"],
        "코인": ["coin", "token"],
        "네트워크": ["network"],
        "알림": ["notification", "alert"],
        "업로드": ["upload"],
        "다운로드": ["download"],
        "프로필": ["profile"],
        "대시보드": ["dashboard"],
        // English synonyms / abbreviations
        "signin": ["login", "auth"],
        "auth": ["authenticate", "authentication", "login"],
        "db": ["database"],
        "config": ["settings", "config"],
        "pw": ["password"],
    ]

    // MARK: - Typo correction

    /// Closest vocabulary word within a length-scaled edit-distance threshold.
    static func closest(_ term: String, in vocab: Set<String>) -> String? {
        guard term.count >= 3 else { return nil }
        let maxDist = term.count >= 6 ? 2 : 1
        var best: String?
        var bestDist = maxDist + 1
        let termChars = Array(term)
        for word in vocab where abs(word.count - term.count) <= maxDist {
            let d = editDistance(termChars, Array(word))
            if d > 0 && d < bestDist { bestDist = d; best = word }
        }
        return bestDist <= maxDist ? best : nil
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
