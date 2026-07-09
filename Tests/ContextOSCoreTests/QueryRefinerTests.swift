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
