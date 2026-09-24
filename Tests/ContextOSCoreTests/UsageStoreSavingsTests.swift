import Foundation
import Testing
@testable import ContextOSCore

@Suite("UsageStore savings")
struct UsageStoreSavingsTests {

    private func event(at ts: Double, selected: Int, full: Int) -> UsageEvent {
        UsageEvent(timestamp: ts, project: "/p", query: "q", selectedTokens: selected,
                   fullTokens: full, contextScore: 50, fileCount: 1)
    }

    @Test("one query gives the count, the all-time total and today's savings")
    func totals() throws {
        let store = try UsageStore(path: ":memory:")
        let midnight = 1_800_000_000.0
        try store.record(event(at: midnight - 3600, selected: 100, full: 1_000))   // yesterday: 900
        try store.record(event(at: midnight + 60, selected: 200, full: 500))       // today: 300
        try store.record(event(at: midnight + 120, selected: 700, full: 400))      // negative → 0

        let totals = store.savingsTotals(since: midnight)
        #expect(totals.queryCount == 3)
        #expect(totals.totalSaved == 1_200)
        #expect(totals.todaySaved == 300)
        // Same figures as the queries it replaces.
        #expect(totals.totalSaved == store.summary().totalSaved)
        #expect(totals.queryCount == store.summary().queryCount)
    }

    @Test("an empty table is all zeros")
    func empty() throws {
        let totals = try UsageStore(path: ":memory:").savingsTotals(since: 0)
        #expect(totals.queryCount == 0 && totals.totalSaved == 0 && totals.todaySaved == 0)
    }

    @Test("pruning by path removes only transcripts that are gone")
    func pruneByPath() throws {
        let store = try UsageStore(path: ":memory:")
        try store.upsertSessionCache([
            SessionCacheRow(path: "/a.jsonl", agent: "Codex", mtime: 1, size: 1),
            SessionCacheRow(path: "/b.jsonl", agent: "Codex", mtime: 1, size: 1),
            SessionCacheRow(path: "/c.jsonl", agent: "Codex", mtime: 1, size: 1)
        ])
        #expect(store.sessionCachePaths() == ["/a.jsonl", "/b.jsonl", "/c.jsonl"])
        store.deleteSessionCache(paths: ["/b.jsonl"])
        store.pruneSessionCache(keeping: ["/a.jsonl"])
        #expect(store.sessionCachePaths() == ["/a.jsonl"])
    }
}
