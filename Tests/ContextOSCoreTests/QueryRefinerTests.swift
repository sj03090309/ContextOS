import Foundation
import Testing
@testable import ContextOSCore

@Suite("QueryRefiner")
struct QueryRefinerTests {
    let refiner = QueryRefiner()

    @Test("expands Korean dev terms to English")
    func koreanExpansion() {
        let r = refiner.refine("로그인 고쳐줘", vocabulary: [])
        #expect(r.terms.contains("login"))
        #expect(r.terms.contains("auth"))
        #expect(r.changed)
        #expect(r.expansions.contains { $0.from == "로그인" })
    }

    @Test("Korean usage and context tasks retain their distinct intents")
    func usageAndContextIntent() {
        let usage = refiner.refine("오늘 관측 토큰 사용량 수집", vocabulary: ["ObservedSession", "ConcurrentUsageReader"])
        #expect(Set(["observed", "usage", "collection", "reader"]).isSubset(of: Set(usage.terms)))
        let context = refiner.refine("컨텍스트 최적화 의존성 누락 중복 절감", vocabulary: [])
        #expect(Set(["context", "optimizer", "dependency", "missing", "dedup", "savings"]).isSubset(of: Set(context.terms)))
    }

    @Test("corrects a typo to a real project symbol")
    func typoCorrection() {
        let r = refiner.refine("fix logn", vocabulary: ["login", "logout", "authenticate"])
        #expect(r.terms.contains("login"))
        #expect(r.corrections.contains { $0.from == "logn" && $0.to == "login" })
    }

    @Test("leaves an already-correct query mostly unchanged")
    func noChange() {
        let r = refiner.refine("authenticate user", vocabulary: ["authenticate", "user"])
        #expect(!r.changed)
        #expect(r.terms.contains("authenticate"))
        #expect(r.terms.contains("user"))
    }

    @Test("does not over-correct short or unrelated tokens")
    func noOverCorrection() {
        let r = refiner.refine("zzzzzz", vocabulary: ["login", "payment"])
        // 'zzzzzz' is far from any vocab word → kept as-is, no bogus correction.
        #expect(r.corrections.isEmpty)
    }

    @Test("edit distance is correct")
    func editDistance() {
        #expect(QueryRefiner.editDistance(Array("login"), Array("logn")) == 1)
        #expect(QueryRefiner.editDistance(Array("kitten"), Array("sitting")) == 3)
    }
}
