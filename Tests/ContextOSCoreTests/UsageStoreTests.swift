import Foundation
import Testing
@testable import ContextOSCore

@Suite("UsageStore")
struct UsageStoreTests {

    @Test("records events and aggregates savings")
    func recordsAndAggregates() throws {
        let store = try UsageStore(path: ":memory:")
        try store.record(UsageEvent(project: "/p/alpha", query: "fix login",
                                    selectedTokens: 1000, fullTokens: 10_000, contextScore: 90, fileCount: 3))
        try store.record(UsageEvent(project: "/p/alpha", query: "add billing",
                                    selectedTokens: 2000, fullTokens: 12_000, contextScore: 80, fileCount: 4))
        try store.record(UsageEvent(project: "/p/beta", query: "x",
                                    selectedTokens: 500, fullTokens: 500, contextScore: 100, fileCount: 1))

        let summary = store.summary()
        #expect(summary.queryCount == 3)
        #expect(summary.totalSaved == 9_000 + 10_000)   // beta saved 0
        #expect(summary.perProject.first?.project == "/p/alpha")
        #expect(store.todaySaved() == 19_000)
    }

    @Test("savedTokens never goes negative")
    func noNegativeSavings() {
        let event = UsageEvent(project: "p", query: "q", selectedTokens: 800,
                               fullTokens: 500, contextScore: 100, fileCount: 1)
        #expect(event.savedTokens == 0)
    }
}
