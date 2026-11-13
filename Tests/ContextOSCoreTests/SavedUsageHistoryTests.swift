import Foundation
import Testing
@testable import ContextOSCore

struct SavedUsageHistoryTests {
    private let firstTimestamp = "2026-07-01T10:00:00Z"
    private let secondTimestamp = "2026-07-02T10:00:00Z"

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-saved-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func expectUnchanged(_ before: [String: SessionCacheRow],
                                 _ after: [String: SessionCacheRow]) throws {
        #expect(Set(before.keys) == Set(after.keys))
        for (path, original) in before {
            let current = try #require(after[path])
            #expect(current.path == original.path)
            #expect(current.agent == original.agent)
            #expect(current.mtime == original.mtime)
            #expect(current.size == original.size)
            #expect(current.cursor == original.cursor)
            #expect(current.lastProject == original.lastProject)
            #expect(current.fileIdentity == original.fileIdentity)
            #expect(current.projects == original.projects)
            #expect(try encoded(current.codexAccounting) == encoded(original.codexAccounting))
            #expect(try encoded(current.claudeAccounting) == encoded(original.claudeAccounting))
        }
    }

    private func expectSameHistory(_ saved: AgentUsageSnapshot, _ live: AgentUsageSnapshot) {
        #expect(saved.totalTokens == live.totalTokens)
        #expect(saved.byAgent == live.byAgent)
        #expect(saved.byProjectAgent == live.byProjectAgent)
        #expect(saved.byDay == live.byDay)
        #expect(saved.byAgentDay == live.byAgentDay)
        #expect(saved.availableAgents == live.availableAgents)
        #expect(saved.sessions.count == live.sessions.count)
    }

    @Test("Saved calendar counters do not depend on missing or malformed source transcripts")
    func savedCountersIgnoreSourceAvailability() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.jsonl")
        let invalid = root.appendingPathComponent("invalid.jsonl")
        let malformedBytes = Data("{not a valid transcript\n".utf8)
        try malformedBytes.write(to: invalid)
        let store = try UsageStore(path: ":memory:")
        try store.upsertSessionCache([
            SessionCacheRow(path: missing.path, agent: "Claude Code", mtime: 1, size: 99,
                            cursor: 3, lastProject: "/fixture/alpha",
                            projects: ["/fixture/alpha": .init(tokens: 120, start: 1, end: 2,
                                                              days: ["2026-07-01": 100, "2026-07-02": 20])]),
            SessionCacheRow(path: invalid.path, agent: "Codex", mtime: 2, size: 199,
                            cursor: 30, lastProject: "/fixture/beta",
                            projects: ["/fixture/beta": .init(tokens: 30, start: 3, end: 4,
                                                             days: ["2026-07-02": 30])])
        ])
        let before = store.sessionCache()
        let saved = AgentSessionReader.savedSnapshot(from: store)
        #expect(saved.totalTokens == 150)
        #expect(saved.byDay == ["2026-07-01": 100, "2026-07-02": 50])
        #expect(saved.byAgent == ["Claude Code": 120, "Codex": 30])
        #expect(saved.byProjectAgent["/fixture/alpha"]?["Claude Code"] == 120)
        #expect(saved.sessions.count == 2)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try Data(contentsOf: invalid) == malformedBytes)
        try expectUnchanged(before, store.sessionCache())
        expectSameHistory(AgentSessionReader.savedSnapshot(from: store), saved)
    }

    @Test("Saved Claude history keeps live high-water message de-duplication after sources disappear")
    func copiedClaudeHistoryMatchesLive() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        func line(_ id: String, _ tokens: Int, _ timestamp: String, _ project: String) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"cwd\":\"\(project)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(tokens)}}}\n"
        }
        let first = root.appendingPathComponent("a.jsonl")
        let second = root.appendingPathComponent("b.jsonl")
        try line("shared", 100, firstTimestamp, "/fixture/alpha")
            .write(to: first, atomically: true, encoding: .utf8)
        try (line("shared", 150, firstTimestamp, "/fixture/alpha")
             + line("unique", 40, secondTimestamp, "/fixture/beta"))
            .write(to: second, atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("usage.sqlite").path
        let live = TranscriptCache(storePath: path)
            .snapshot(of: [(first, "Claude Code"), (second, "Claude Code")])
        #expect(live.totalTokens == 190)
        let store = try UsageStore(path: path)
        let before = store.sessionCache()
        try FileManager.default.removeItem(at: first)
        try "invalid after collection".write(to: second, atomically: true, encoding: .utf8)

        let saved = AgentSessionReader.savedSnapshot(from: store)
        expectSameHistory(saved, live)
        #expect(saved.byProjectAgent["/fixture/alpha"]?["Claude Code"] == 150)
        #expect(saved.byProjectAgent["/fixture/beta"]?["Claude Code"] == 40)
        #expect(saved.byDay[TimeKeys.localDay(try #require(TimeKeys.epoch(fromISO8601: firstTimestamp)))] == 150)
        #expect(saved.byDay[TimeKeys.localDay(try #require(TimeKeys.epoch(fromISO8601: secondTimestamp)))] == 40)
        try expectUnchanged(before, store.sessionCache())
    }

    @Test("Saved modern Codex history counts copied request records once, matching live history")
    func copiedCodexRequestsMatchLive() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture-thread\",\"cwd\":\"/fixture/project\"}}\n"
        func request(_ id: String, _ tokens: Int, _ timestamp: String) -> String {
            "{\"type\":\"token_usage_record\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"thread_id\":\"fixture-thread\",\"response_id\":\"\(id)\",\"usage\":{\"total_tokens\":\(tokens)}}}\n"
        }
        let first = root.appendingPathComponent("rollout-a.jsonl")
        let second = root.appendingPathComponent("rollout-b.jsonl")
        try (meta + request("response-1", 100, firstTimestamp))
            .write(to: first, atomically: true, encoding: .utf8)
        try (meta + request("response-1", 100, firstTimestamp)
             + request("response-2", 40, secondTimestamp))
            .write(to: second, atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("usage.sqlite").path
        let live = TranscriptCache(storePath: path).snapshot(of: [(first, "Codex"), (second, "Codex")])
        #expect(live.totalTokens == 140)
        let store = try UsageStore(path: path)
        let before = store.sessionCache()
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)

        let saved = AgentSessionReader.savedSnapshot(from: store)
        expectSameHistory(saved, live)
        #expect(saved.byAgent == ["Codex": 140])
        #expect(saved.byDay[TimeKeys.localDay(try #require(TimeKeys.epoch(fromISO8601: firstTimestamp)))] == 100)
        #expect(saved.byDay[TimeKeys.localDay(try #require(TimeKeys.epoch(fromISO8601: secondTimestamp)))] == 40)
        try expectUnchanged(before, store.sessionCache())
    }

    @Test("Saved modern request records replace their legacy session copies without suppressing other sessions")
    func modernAndLegacyCopiesDoNotDoubleCount() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = try #require(TimeKeys.epoch(fromISO8601: firstTimestamp))
        let day = TimeKeys.localDay(epoch)
        let project = "/fixture/project"
        var copiedLegacy = SessionCacheRow(path: root.appendingPathComponent("a-legacy.jsonl").path,
                                          agent: "Codex", mtime: 1, size: 100,
                                          projects: [project: .init(tokens: 800, start: epoch, end: epoch,
                                                                    days: [day: 800])])
        var legacyAccounting = CodexSessionAccounting()
        legacyAccounting.session = "shared-session"
        legacyAccounting.legacyCounter = 800
        copiedLegacy.codexAccounting = legacyAccounting
        var modern = SessionCacheRow(path: root.appendingPathComponent("b-modern.jsonl").path,
                                     agent: "Codex", mtime: 2, size: 200)
        var modernAccounting = CodexSessionAccounting()
        modernAccounting.session = "shared-session"
        modernAccounting.usesRequests = true
        modernAccounting.requests = ["response": .init(tokens: 130, timestamp: epoch, project: project)]
        modern.codexAccounting = modernAccounting
        var independent = copiedLegacy
        independent.path = root.appendingPathComponent("c-independent.jsonl").path
        independent.projects = [project: .init(tokens: 50, start: epoch, end: epoch, days: [day: 50])]
        independent.codexAccounting?.session = "other-session"
        independent.codexAccounting?.legacyCounter = 50
        let store = try UsageStore(path: ":memory:")
        try store.upsertSessionCache([copiedLegacy, modern, independent])
        let before = store.sessionCache()

        let saved = AgentSessionReader.savedSnapshot(from: store)
        #expect(saved.totalTokens == 180)
        #expect(saved.byAgent == ["Codex": 180])
        #expect(saved.byDay == [day: 180])
        #expect(saved.byProjectAgent[project]?["Codex"] == 180)
        #expect(saved.sessions.count == 2)
        try expectUnchanged(before, store.sessionCache())
    }
}
