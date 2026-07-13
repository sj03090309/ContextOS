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
            //    Korean particles are stripped so "삭제가"/"결제를" still match.
            if let mapped = Self.dictionaryEntry(for: term) {
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

    /// Dictionary lookup that survives Korean particles: "삭제가" → "삭제",
    /// "결제를" → "결제". Longest particles are tried first.
    static func dictionaryEntry(for term: String) -> [String]? {
        if let hit = dictionary[term] { return hit }
        for particle in particles where term.count > particle.count && term.hasSuffix(particle) {
            if let hit = dictionary[String(term.dropLast(particle.count))] { return hit }
        }
        return nil
    }

    /// Common Korean particles/suffixes, longest first so "에서" wins over "에".
    static let particles = [
        "에서", "으로", "부터", "까지", "하고", "이랑", "에는", "에도",
        "가", "이", "은", "는", "을", "를", "도", "만", "에", "로", "와", "과", "랑", "요"
    ]

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
        "삭제": ["delete", "remove"],
        "추가": ["add", "insert", "create"],
        "저장": ["save", "store", "persist"],
        "불러오기": ["load", "fetch", "read"],
        "목록": ["list"],
        "리스트": ["list"],
        "화면": ["view", "screen", "page"],
        "페이지": ["page", "view"],
        "버튼": ["button"],
        "메뉴": ["menu"],
        "이미지": ["image", "photo"],
        "사진": ["photo", "image"],
        "파일": ["file"],
        "폴더": ["folder", "directory"],
        "주문": ["order"],
        "장바구니": ["cart", "basket"],
        "배송": ["shipping", "delivery"],
        "리뷰": ["review"],
        "댓글": ["comment", "reply"],
        "게시글": ["post", "article"],
        "게시판": ["board", "post"],
        "채팅": ["chat", "message"],
        "메시지": ["message"],
        "친구": ["friend"],
        "팔로우": ["follow"],
        "좋아요": ["like", "favorite"],
        "즐겨찾기": ["favorite", "bookmark"],
        "통계": ["stats", "statistics", "analytics"],
        "그래프": ["graph", "chart"],
        "차트": ["chart", "graph"],
        "로그": ["log", "logging"],
        "캐시": ["cache"],
        "백업": ["backup"],
        "동기화": ["sync", "synchronize"],
        "권한": ["permission", "auth", "role"],
        "보안": ["security", "secure"],
        "테스트": ["test"],
        "빌드": ["build"],
        "배포": ["deploy", "release"],
        "성능": ["performance", "perf"],
        "속도": ["speed", "performance"],
        "메모리": ["memory"],
        "애니메이션": ["animation", "animate"],
        "아이콘": ["icon"],
        "색상": ["color", "theme"],
        "색깔": ["color"],
        "폰트": ["font", "typography"],
        "날짜": ["date"],
        "시간": ["time", "date"],
        "위치": ["location", "position"],
        "지도": ["map"],
        "카메라": ["camera"],
        "번역": ["translate", "localization", "i18n"],
        "언어": ["language", "locale"],
        "다크모드": ["dark", "theme", "appearance"],
        "테마": ["theme", "appearance"],
        "환불": ["refund"],
        "쿠폰": ["coupon", "discount"],
        "할인": ["discount", "sale"],
        "포인트": ["point", "reward"],
        "재고": ["stock", "inventory"],
        "상품": ["product", "item"],
        "가격": ["price", "cost"],
        "요청": ["request"],
        "응답": ["response"],
        "서버": ["server", "api"],
        "클라이언트": ["client"],
        "연결": ["connect", "connection"],
        "느림": ["slow", "performance"],
        "느려": ["slow", "performance"],
        "깨짐": ["broken", "crash", "bug"],
        "깨져": ["broken", "crash", "bug"],
        "튕김": ["crash"],
        "튕겨": ["crash"],
        "멈춤": ["hang", "freeze", "crash"],
        "멈춰": ["hang", "freeze", "crash"],
        "충돌": ["crash", "conflict"],
        "버그": ["bug", "fix", "error"],
        "수정": ["fix", "update", "edit"],
        "리팩토링": ["refactor"],
        "최적화": ["optimize", "performance"],
        "마스코트": ["mascot"],
        "훅": ["hook"],
        "커밋": ["commit"],
        "브랜치": ["branch"],
        "정렬": ["sort", "order"],
        "필터": ["filter"],
        "변환": ["convert", "transform", "parse"],
        "유효성": ["validation", "validate"],
        "검증": ["validate", "verify"],
        "초기화": ["init", "reset", "initialize"],
        "상태": ["state", "status"],
        "이벤트": ["event"],
        "클릭": ["click", "tap"],
        "입력": ["input"],
        "출력": ["output"],
        "스크롤": ["scroll"],
        "새로고침": ["refresh", "reload"],
        "모달": ["modal", "dialog"],
        "팝업": ["popup", "modal"],
        "토글": ["toggle"],
        "로딩": ["loading", "spinner"],
        "진행률": ["progress"],
        "큐": ["queue"],
        "스택": ["stack"],
        "노드": ["node"],
        "라우팅": ["routing", "route", "router"],
        "라우트": ["route", "router"],
        "쿠키": ["cookie"],
        "헤더": ["header"],
        "인덱스": ["index"],
        "쿼리": ["query"],
        "스키마": ["schema"],
        "마이그레이션": ["migration", "migrate"],
        "구독": ["subscribe", "subscription"],
        "웹소켓": ["websocket", "socket"],
        "소켓": ["socket"],
        "폼": ["form"],
        "필드": ["field"],
        "탭": ["tab"],
        "사이드바": ["sidebar"],
        "네비게이션": ["navigation", "navbar"],
        "라이브러리": ["library", "dependency"],
        "의존성": ["dependency"],
        "패키지": ["package"],
        "모듈": ["module"],
        "컴포넌트": ["component"],
        "훅스": ["hook", "hooks"],
        // English synonyms / abbreviations
        "signin": ["login", "auth"],
        "auth": ["authenticate", "authentication", "login"],
        "db": ["database"],
        "config": ["settings", "config"],
        "pw": ["password"],
        "img": ["image"],
        "btn": ["button"],
        "msg": ["message"],
        "nav": ["navigation", "navbar"],
        "api": ["api", "endpoint", "server"],
        "ui": ["view", "interface", "screen"],
        "crash": ["crash", "exception", "fatal"],
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
