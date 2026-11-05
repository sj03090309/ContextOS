import Foundation
import Testing
@testable import ContextOSCore
import ContextOSUsage

@Suite struct UsageCollectionRegressionTests {
    private let fixture = ConcurrentUsageTests()
    private func response(_ id: String, thread: String = "a", tokens: Int = 20,
                          seconds: Double = -5) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": fixture.stamp(seconds),
         "payload": ["thread_id": thread, "response_id": id,
                     "usage": ["total_tokens": tokens, "input_tokens": tokens, "output_tokens": 0]]]
    }

    @Test func requestRecordsReplaceLegacyEchoesAndPaginatedLifetimeBaselines() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try fixture.write(fixture.meta("a") + [fixture.counter(900_000, -20),
            response("r1"), fixture.counter(900_020, -4), response("r2", tokens: 30, seconds: -2)],
            ".codex/sessions/rollout-a.jsonl", home: h)
        let reader = ConcurrentUsageReader()
        let value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.today == 50)
        #expect(value.widget.providers.first?.state == .ready)
        let copy = file.deletingLastPathComponent().appendingPathComponent("rollout-copy.jsonl")
        try FileManager.default.copyItem(at: file, to: copy)
        #expect(reader.snapshot(home: h, now: fixture.now, timeZone: .gmt).widget.today == 50)
    }

    @Test func requestAccountingPreservesDateModelSwitchesAndExplicitZero() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        _ = try fixture.write(fixture.meta("a", model: "earlier-model") + [
            response("yesterday", tokens: 400, seconds: -3600), response("today-1"),
            ["type": "turn_context", "timestamp": fixture.stamp(-4), "payload": ["model": "new-model"]],
            response("today-2", tokens: 30, seconds: -3), response("zero", tokens: 0, seconds: -2)],
            ".codex/sessions/rollout-a.jsonl", home: h)
        let value = ConcurrentUsageReader().snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.today == 50 && value.widget.yesterday == 400)
        #expect(value.todayModels.first { $0.key.model == "earlier-model" }?.tokens == 20)
        #expect(value.todayModels.first { $0.key.model == "new-model" }?.tokens == 30)
    }

    @Test func forkOwnRequestsAreCountedWithoutReplayingParentsOrRenamingSession() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        _ = try fixture.write(fixture.meta("parent") + [response("parent-r", thread: "parent", tokens: 100)],
            ".codex/sessions/rollout-parent.jsonl", home: h)
        let child: [String: Any] = ["type": "session_meta", "timestamp": fixture.stamp(-90),
            "payload": ["id": "child", "forked_from_id": "parent", "source": "subagent"]]
        _ = try fixture.write([child] + fixture.meta("parent") + [
            response("parent-r", thread: "parent", tokens: 100), fixture.counter(5_000),
            response("child-r", thread: "child", tokens: 30)], ".codex/sessions/rollout-child.jsonl", home: h)
        let value = ConcurrentUsageReader().snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.today == 130 && value.sessions.count == 2)
        #expect(value.sessions.first { $0.origin == .subagent }?.todayTokens == 30)
        #expect(value.widget.providers.first?.state == .ready)
    }

    @Test func oldFilesDoNotConsumeRecentFileLimitButRecentOverflowStillWarns() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        for n in 0..<3 {
            let file = try fixture.write(fixture.meta("old-\(n)") + [fixture.counter(100, -8 * 86400)],
                ".codex/sessions/rollout-old-\(n).jsonl", home: h)
            try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(-8 * 86400)], ofItemAtPath: file.path)
        }
        _ = try fixture.write(fixture.meta("a") + [fixture.counter(20)], ".codex/sessions/rollout-new.jsonl", home: h)
        let reader = ConcurrentUsageReader(maximumFilesPerProvider: 1)
        let value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.today == 20 && value.widget.providers.first?.state == .ready)
        _ = try fixture.write(fixture.meta("b") + [fixture.counter(30)], ".codex/sessions/rollout-second.jsonl", home: h)
        #expect(reader.snapshot(home: h, now: fixture.now, timeZone: .gmt).widget.providers.first?.issues == [.fileLimit])
    }

    @Test func oversizedToolOutputDoesNotBecomePermanentUsageFailureAndBacklogConverges() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try fixture.write(fixture.meta("a") + [response("r1")], ".codex/sessions/rollout-a.jsonl", home: h)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("{\"type\":\"response_item\",\"payload\":{\"text\":\"" + String(repeating: "x", count: 6000) + "\"}}\n").utf8))
        var last = try JSONSerialization.data(withJSONObject: response("r2", tokens: 30)); last.append(10)
        try handle.write(contentsOf: last); try handle.close()
        let reader = ConcurrentUsageReader(maximumLineBytes: 512, maximumReadBytes: 1024)
        var value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.health == "기록 집계 중")
        #expect(value.widget.providers.first?.issues == nil)
        for _ in 0..<12 { value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt) }
        #expect(value.widget.today == 50 && value.widget.health == "로컬 기록 집계")
        #expect(value.widget.providers.first?.isCollecting == nil)
    }

    @Test func oversizedAccountingAndUnknownHeadersKeepExplicitLossWarnings() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try fixture.write([fixture.claude()], ".claude/projects/p/a.jsonl", home: h)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(("{\"type\":\"assistant\",\"message\":{\"content\":\"" + String(repeating: "x", count: 6000) + "\"}}\n").utf8))
        try handle.close()
        let reader = ConcurrentUsageReader(maximumLineBytes: 512, maximumReadBytes: 1024)
        var value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt)
        for _ in 0..<12 { value = reader.snapshot(home: h, now: fixture.now, timeZone: .gmt) }
        #expect(value.widget.today == 200)
        #expect(value.widget.providers.first { $0.name == "Claude Code" }?.issues == [.oversizedRecord])
        let nested = Data("{\"payload\":{\"type\":\"response_item\"},\"type\":\"event_msg\"}".utf8)
        #expect(nested.withUnsafeBytes { LineReader.envelopeType(in: $0) } == "event_msg")
        let unknown = Data("{\"payload\":{\"type\":\"response_item\"}}".utf8)
        #expect(unknown.withUnsafeBytes { LineReader.envelopeType(in: $0) } == nil)
    }

    @Test func malformedRequestCannotCreateObservedZeroAndLimitsRemainVisible() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        _ = try fixture.write(fixture.meta("a") + [response("bad", tokens: -1)], ".codex/sessions/rollout-a.jsonl", home: h)
        let value = ConcurrentUsageReader().snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(value.widget.today == nil && value.widget.providers.first?.issues == [.invalidRecord])
        _ = try fixture.write(fixture.meta("b") + [response("ok", thread: "b"), response("over", thread: "b")],
            ".codex/sessions/rollout-b.jsonl", home: h)
        let bounded = ConcurrentUsageReader(maximumMetrics: 1).snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(bounded.widget.providers.first?.issues?.contains(.recordLimit) == true)
    }

    @Test func collectionProgressAndFailureReasonsRoundTripWithoutPrivateMetadata() throws {
        let value = WidgetUsageSnapshot(providers: [.init(name: "Codex", state: .partial, isCollecting: true)])
        #expect(value.health == "기록 집계 중")
        let encoded = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(WidgetUsageSnapshot.self, from: encoded) == value)
        let legacy = WidgetUsageSnapshot(providers: [.init(name: "Codex", state: .partial)])
        #expect(try JSONDecoder().decode(WidgetUsageSnapshot.self, from: JSONEncoder().encode(legacy)) == legacy)
        #expect(legacy.health == "일부 기록만 수집")
    }

    @Test func calendarCacheUpgradesDerivedRowsAndAgreesWithObservedRequestTotals() throws {
        let h = try fixture.home(); defer { try? FileManager.default.removeItem(at: h) }
        let file = try fixture.write(fixture.meta("a") + [fixture.counter(900_000), response("r1"), fixture.counter(900_020)],
            ".codex/sessions/rollout-a.jsonl", home: h)
        let db = h.appendingPathComponent("usage.sqlite").path
        let store = try UsageStore(path: db)
        var legacy = try #require(AgentSessionReader.row(for: file, agent: "Codex", cached: nil))
        legacy.codexAccounting = nil
        legacy.projects = ["/private/project": .init(tokens: 999_999)]
        try store.upsertSessionCache([legacy])
        let files = [(url: file, agent: "Codex")]
        let first = TranscriptCache(storePath: db).snapshot(of: files)
        #expect(first.totalTokens == 20)
        let persisted = try #require(store.sessionCache()[file.path])
        #expect(persisted.codexAccounting?.usesRequests == true)
        let copy = file.deletingLastPathComponent().appendingPathComponent("rollout-copy.jsonl")
        try FileManager.default.copyItem(at: file, to: copy)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        var more = try JSONSerialization.data(withJSONObject: response("r2", tokens: 30)); more.append(10)
        try handle.write(contentsOf: more); try handle.close()
        let warm = TranscriptCache(storePath: db).snapshot(of: files + [(url: copy, agent: "Codex")])
        let observed = ConcurrentUsageReader().snapshot(home: h, now: fixture.now, timeZone: .gmt)
        #expect(warm.totalTokens == 50 && observed.widget.today == 50)
        #expect(warm.byDay.values.reduce(0, +) == 50)
        store.pruneSessionCache(keeping: [])
        #expect(store.sessionCache().isEmpty)
    }
}
