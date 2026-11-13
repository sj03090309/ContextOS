import Foundation
import Testing
import SQLite3
@testable import ContextOSCore

@Suite("Core audit regressions")
struct CoreAuditRegressionTests {
    @Test("An exact project-relative file wins over smaller files sharing its basename")
    func exactRelativeFileReference() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Windows"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try String(repeating: "Root project guide\n", count: 40).write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "Nested guide\n".write(to: directory.appendingPathComponent("Windows/README.md"), atomically: true, encoding: .utf8)
        let result = try ContextService(useGitSignals: false).relevantContext(query: "README.md", projectRoot: directory, tokenBudget: 8000)
        #expect(result.included.first?.path == "README.md")
        #expect(!result.included.contains(where: { $0.path == "Windows/README.md" }))
    }

    @Test("A following array table cannot supply or receive the ContextOS command")
    func codexArrayTableBoundary() throws {
        let source = "[mcp_servers.contextos]\nargs = []\n[[skills.config]]\ncommand = \"USER_TOOL\"\npath = \"/user/skill\"\n"
        var editor = try CodexSettingsEditor(Data(source.utf8))
        #expect(try editor.value("command") == nil)
        try editor.set("command", to: "\"/installed/contextos-mcp\"")
        #expect(editor.text.contains("[[skills.config]]\ncommand = \"USER_TOOL\""))
        #expect(editor.text.contains("[mcp_servers.contextos]\ncommand = \"/installed/contextos-mcp\""))
    }

    @Test("Inline and dotted registrations are refused instead of creating duplicate TOML tables")
    func codexInlineRegistration() throws {
        for source in [
            "mcp_servers = { contextos = { command = \"old\", args = [] } }\n",
            "[mcp_servers]\ncontextos = { command = \"old\", args = [] }\n",
            "mcp_servers.contextos.command = \"old\"\n"
        ] {
            #expect(throws: SettingsSafetyError.self) {
                var editor = try CodexSettingsEditor(Data(source.utf8))
                try editor.addSection(command: "/installed/contextos-mcp")
            }
        }
    }

    @Test("Claude historical accounting counts one streamed message and excludes synthetic/sidechain usage")
    func claudeStreamedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.jsonl")
        func line(_ id: String, output: Int, extra: String = "", model: String = "claude-test") -> String {
            "{\"type\":\"assistant\",\"sessionId\":\"session\",\"timestamp\":\"2026-07-01T10:00:00Z\",\"cwd\":\"/project\",\(extra)\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":100,\"output_tokens\":\(output)}}}\n"
        }
        try (line("message", output: 10) + line("message", output: 20)
             + line("synthetic", output: 50, model: "<synthetic>")
             + line("child", output: 80, extra: "\"isSidechain\":true,")).write(to: url, atomically: true, encoding: .utf8)
        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(first.tokens == 120)
        let store = try UsageStore(path: directory.appendingPathComponent("cache.sqlite").path)
        try store.upsertSessionCache([first])
        let cached = try #require(store.sessionCache()[url.path])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(line("message", output: 30).utf8)); try handle.close()
        let resumed = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: cached))
        #expect(resumed.tokens == 130)
        let cache = TranscriptCache(storePath: directory.appendingPathComponent("snapshot.sqlite").path)
        let copy = directory.appendingPathComponent("copy.jsonl")
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(cache.snapshot(of: [(url, "Claude Code"), (copy, "Claude Code")]).totalTokens == 130)
    }

    @Test("Malformed dates and incomplete zone suffixes are rejected safely")
    func malformedTimestamps() {
        for stamp in ["2026-07-01T10:00:00+", "2026-07-01T10:00:00+0", "2026-07-01T10:00:00+09:",
                      "2026-02-30T10:00:00Z", "2026-07-01T10:00:00Zgarbage", "2026-07-01T10:00:00.Z",
                      "2026-07-01T10:00:00+25:00"] {
            #expect(TimeKeys.epoch(fromISO8601: stamp) == nil)
        }
    }

    @Test("Local midnight and day buckets honor DST and the requested zone")
    func daylightSavingBoundaries() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let epoch = try #require(TimeKeys.epoch(fromISO8601: "2026-03-08T16:00:00Z"))
        let midnight = try #require(TimeKeys.epoch(fromISO8601: "2026-03-08T05:00:00Z"))
        #expect(TimeKeys.localStartOfDay(epoch, timeZone: zone) == midnight)
        #expect(BuildLogReader.dayStart("2026-03-08", timeZone: zone) == midnight)
        #expect(BuildLogReader.dayStart("2026-01-15", timeZone: zone)
            == TimeKeys.epoch(fromISO8601: "2026-01-15T05:00:00Z"))
        #expect(BuildLogReader.dayStart("2026-02-30", timeZone: zone) == 0)
        let late = try #require(TimeKeys.epoch(fromISO8601: "2026-03-09T04:30:00Z"))
        #expect(TimeKeys.localDay(late, timeZone: zone) == "2026-03-09")
        #expect(TimeKeys.localDay(late, timeZone: .gmt) == "2026-03-09")
        let sameUTCDate = try #require(TimeKeys.epoch(fromISO8601: "2026-03-08T04:30:00Z"))
        #expect(TimeKeys.localDay(sameUTCDate, timeZone: zone) == "2026-03-07")
        #expect(TimeKeys.localDay(sameUTCDate, timeZone: .gmt) == "2026-03-08")
    }

    @Test("Large or malformed transcript counters never overflow or invent a reset")
    func transcriptCounterBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/project\"}}\n"
        func counter(_ n: String) -> String {
            "{\"type\":\"event_msg\",\"timestamp\":\"2026-07-01T10:00:00Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(n)}}}}\n"
        }
        try (meta + counter(String(Int.max))).write(to: file, atomically: true, encoding: .utf8)
        let first = try #require(AgentSessionReader.row(for: file, agent: "Codex", cached: nil))
        #expect(first.tokens == Int.max)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((counter("-1") + counter(String(Int.max))).utf8)); try handle.close()
        let next = try #require(AgentSessionReader.row(for: file, agent: "Codex", cached: first))
        #expect(next.tokens == Int.max)
    }

    @Test("Claude high-water copies and cwd metadata produce one correctly attributed total")
    func claudeCopiesAndMetadata() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.jsonl")
        let copy = root.appendingPathComponent("b.jsonl")
        func line(_ tokens: Int) -> String {
            "{\"timestamp\":\"2026-07-01T10:00:00Z\",\"message\":{\"id\":\"shared-message\",\"usage\":{\"input_tokens\":\(tokens)}}}\n"
        }
        try ("{\"cwd\":\"/correct-project\"}\n" + line(100)).write(to: first, atomically: true, encoding: .utf8)
        try ("{\"cwd\":\"/correct-project\"}\n" + line(120)).write(to: copy, atomically: true, encoding: .utf8)
        let path = root.appendingPathComponent("cache.sqlite").path
        let cache = TranscriptCache(storePath: path)
        let files = [(first, "Claude Code"), (copy, "Claude Code")]
        let snapshot = cache.snapshot(of: files)
        #expect(snapshot.totalTokens == 120)
        #expect(snapshot.byProjectAgent["/correct-project"]?["Claude Code"] == 120)
        #expect(TranscriptCache(storePath: path).snapshot(of: files).totalTokens == 120)
    }

    @Test("Bounded counters remain safe through the project and journal summaries")
    func largeCounterSummaries() {
        var usage = AgentUsageSnapshot()
        usage.byProjectAgent = ["/fixture": ["Claude Code": Int.max, "Codex": Int.max]]
        usage.byDay = ["2026-07-01": Int.max, "2026-07-02": Int.max]
        #expect(ProjectAITokenReader.topProjects(snapshot: usage).first?.total == Int.max)
        #expect(BuildLogReader.log(since: 0, snapshot: usage, repos: []).summary.tokens == Int.max)
    }

    @Test("Usage DB initialization waits for an existing writer before requesting WAL")
    func usageDatabaseWriterContention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("usage.sqlite").path
        let writer = try LockedDatabase(path)
        #expect(sqlite3_exec(writer.db, "CREATE TABLE keep(value); BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            sqlite3_exec(writer.db, "COMMIT;", nil, nil, nil)
            released.signal()
        }
        defer { _ = released.wait(timeout: .now() + 2) }
        let store = try UsageStore(path: path)
        #expect(store.summary().queryCount == 0)
    }

    @Test("Git paths preserve Korean names, literal arrows, whitespace and renames")
    func gitPaths() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = ["한글 파일.swift", "arrow -> literal.txt", " line\nbreak.py", "old.swift"]
        for path in originals {
            try "original\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try commit(root)
        #expect(GitAnalyzer().recentlyModifiedFiles(root) == Set(originals))
        for path in originals.dropLast() {
            try "changed\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        #expect(GitRunner.run(["mv", "old.swift", "새 파일.swift"], in: root) != nil)
        #expect(GitAnalyzer().changedFiles(root) == Set(originals.dropLast()).union(["새 파일.swift"]))
        try commit(root)
        #expect(GitAnalyzer().recentlyModifiedFiles(root, commitLimit: 1)
            == Set(originals.dropLast()).union(["새 파일.swift"]))
    }

    @Test("Cached Git history refreshes attribution when new session data arrives")
    func buildAttributionRefresh() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello\n".write(to: root.appendingPathComponent("code.swift"), atomically: true, encoding: .utf8)
        try commit(root)
        let since = Date().timeIntervalSince1970 - 3600
        let first = try #require(BuildLogReader.commits(in: root, since: since, usage: .init()).first)
        #expect(first.agents.isEmpty)
        var snapshot = AgentUsageSnapshot()
        snapshot.sessions = [.init(agent: "Codex", project: root.path,
                                   start: first.timestamp - 1, end: first.timestamp + 1, tokens: 10)]
        let refreshed = try #require(BuildLogReader.commits(in: root, since: since, usage: snapshot).first)
        #expect(refreshed.agents == ["Codex"])
    }

    @Test("Git diagnostics larger than a pipe buffer cannot block stdout")
    func gitNoisyDiagnostics() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = "!i=0; while [ \"$i\" -lt 20000 ]; do echo noise >&2; i=$((i+1)); done; printf ok"
        #expect(GitRunner.run(["-c", "alias.audit-noisy=" + alias, "audit-noisy"], in: root) == "ok")
    }

    @Test("A clock rollback expires session delivery memory instead of extending its TTL")
    func sessionMemoryClockRollback() {
        let memory = SessionMemory(ttl: 60)
        let now = Date()
        memory.markServed(project: "/project", path: "code.swift", bodyHash: "hash", now: now)
        #expect(!memory.isUnchanged(project: "/project", path: "code.swift", bodyHash: "hash",
                                    now: now.addingTimeInterval(-3600)))
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(GitRunner.run(["init", "-q"], in: root) != nil)
        return root
    }

    private func commit(_ root: URL) throws {
        #expect(GitRunner.run(["add", "."], in: root) != nil)
        #expect(GitRunner.run(["-c", "core.hooksPath=/dev/null", "-c", "user.name=Audit Fixture",
                              "-c", "user.email=audit@example.invalid", "commit", "-qm", "Fixture"], in: root) != nil)
    }
}

private final class LockedDatabase: @unchecked Sendable {
    let db: OpaquePointer
    init(_ path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw CocoaError(.fileWriteUnknown) }
        db = handle
    }
    deinit { sqlite3_close(db) }
}
