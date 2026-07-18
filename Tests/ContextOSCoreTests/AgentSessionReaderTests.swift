import Foundation
import Testing
@testable import ContextOSCore

@Suite("AgentSessionReader")
struct AgentSessionReaderTests {

    // MARK: - Fixtures

    private func tempFile(_ name: String, _ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        // Bump mtime so the reader notices; APFS timestamps are coarse enough
        // that a fast test could otherwise write within the same tick.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// One Claude Code transcript line with a usage block.
    private func claudeLine(_ timestamp: String, input: Int, output: Int,
                            cwd: String = "/tmp/proj") -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"\(cwd)","message":{"usage":\
        {"input_tokens":\(input),"cache_read_input_tokens":0,"cache_creation_input_tokens":0,\
        "output_tokens":\(output)}}}
        """
    }

    /// One Codex `token_count` event carrying a cumulative total.
    private func codexLine(_ timestamp: String, cumulative: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"total_tokens":\(cumulative)}}}}
        """
    }

    private func codexMeta(_ timestamp: String, cwd: String = "/tmp/proj") -> String {
        """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"cwd":"\(cwd)"}}
        """
    }

    // MARK: - Claude Code

    @Test("sums Claude usage and buckets it by local day")
    func parsesClaude() throws {
        let url = try tempFile("session.jsonl", [
            claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 20),
            claudeLine("2026-07-01T11:00:00.000Z", input: 50, output: 5),
            claudeLine("2026-07-02T10:00:00.000Z", input: 200, output: 30),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let row = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(row.tokens == 405)
        let bucket = try #require(row.projects["/tmp/proj"])
        #expect(bucket.tokens == 405)
        #expect(bucket.days.values.reduce(0, +) == 405)
        #expect(bucket.days.count == 2)
        #expect(bucket.start < bucket.end)
    }

    @Test("prefers the recorded cwd over the lossy encoded directory name")
    func prefersRecordedCwd() throws {
        // A project whose own folder name contains "-" cannot be recovered from
        // the encoded directory name, so the cwd in the transcript is the only
        // reliable source.
        let url = try tempFile("s.jsonl",
                               claudeLine("2026-07-01T10:00:00.000Z", input: 10, output: 1,
                                          cwd: "/Users/me/my-cool-app") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let row = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(row.projects.keys.sorted() == ["/Users/me/my-cool-app"])
        // What the old directory-name decoding would have produced instead:
        #expect(AgentSessionReader.decodeClaudeDir("-Users-me-my-cool-app") == "/Users/me/my/cool/app")
    }

    @Test("a session that moves between directories splits its usage per directory")
    func splitsUsageAcrossDirectories() throws {
        // A transcript is not pinned to the directory it started in — the user
        // `cd`s, or resumes the session elsewhere. Attributing the whole file to
        // whichever cwd it happened to end in silently moves one project's
        // tokens onto another; on a real machine this misplaced ~10% of them.
        let url = try tempFile("session.jsonl", [
            claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 0, cwd: "/tmp/alpha"),
            claudeLine("2026-07-01T11:00:00.000Z", input: 30, output: 0, cwd: "/tmp/beta"),
            claudeLine("2026-07-01T12:00:00.000Z", input: 5, output: 0, cwd: "/tmp/beta"),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let row = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(row.tokens == 135)
        #expect(row.projects["/tmp/alpha"]?.tokens == 100)
        #expect(row.projects["/tmp/beta"]?.tokens == 35)
        // Each directory keeps its own span, so commit attribution stays honest.
        #expect(row.projects["/tmp/alpha"]?.end != row.projects["/tmp/beta"]?.end)
    }

    @Test("a line with no cwd inherits the last directory seen, across chunks")
    func inheritsLastCwd() throws {
        let bare = """
        {"type":"assistant","timestamp":"2026-07-01T11:00:00.000Z","message":{"usage":\
        {"input_tokens":7,"output_tokens":0}}}
        """
        let url = try tempFile("session.jsonl",
                               claudeLine("2026-07-01T10:00:00.000Z", input: 10, output: 0,
                                          cwd: "/tmp/alpha") + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        try append(url, bare + "\n")
        // The cwd was only stated in the earlier chunk; the tail read must
        // remember it rather than dropping the tokens.
        let second = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: first))
        #expect(second.projects["/tmp/alpha"]?.tokens == 17)
        #expect(second.projects.count == 1)
    }

    // MARK: - Codex

    @Test("differences Codex's cumulative totals into per-day work")
    func parsesCodexCumulative() throws {
        // Codex reports a running total, not a delta. Summing the totals would
        // report 600 instead of the 300 actually used.
        let url = try tempFile("rollout-x.jsonl", [
            codexMeta("2026-07-01T09:00:00.000Z"),
            codexLine("2026-07-01T10:00:00.000Z", cumulative: 100),
            codexLine("2026-07-01T11:00:00.000Z", cumulative: 250),
            codexLine("2026-07-02T10:00:00.000Z", cumulative: 300),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let row = try #require(AgentSessionReader.row(for: url, agent: "Codex", cached: nil))
        #expect(row.tokens == 300)                  // the final cumulative, not 650
        let bucket = try #require(row.projects["/tmp/proj"])
        #expect(bucket.days.values.reduce(0, +) == 300)
        // Day one did 250, day two added the remaining 50.
        #expect(bucket.days["2026-07-01"] == 250)
        #expect(bucket.days["2026-07-02"] == 50)
        #expect(row.cursor == 300)
    }

    @Test("a cumulative counter that restarts does not produce negative work")
    func codexCounterReset() throws {
        let url = try tempFile("rollout-y.jsonl", [
            codexMeta("2026-07-01T09:00:00.000Z"),
            codexLine("2026-07-01T10:00:00.000Z", cumulative: 500),
            codexLine("2026-07-01T11:00:00.000Z", cumulative: 80),   // restarted
            codexLine("2026-07-01T12:00:00.000Z", cumulative: 120),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let row = try #require(AgentSessionReader.row(for: url, agent: "Codex", cached: nil))
        #expect(row.tokens == 620)                  // 500 + 80 + 40, never negative
    }

    // MARK: - Incremental reads

    @Test("an unchanged file is not re-read")
    func unchangedFileReusesCache() throws {
        let url = try tempFile("session.jsonl", claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 20) + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        let second = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: first))
        #expect(second.tokens == first.tokens)
        #expect(second.size == first.size)
    }

    @Test("appending to a transcript matches a full re-parse, without double counting")
    func incrementalMatchesFullParse() throws {
        // This is the whole risk of tail-reading: if the resume offset is wrong,
        // tokens get counted twice or dropped, silently.
        let url = try tempFile("session.jsonl",
                               claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 20) + "\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(first.tokens == 120)

        try append(url, claudeLine("2026-07-01T11:00:00.000Z", input: 50, output: 5) + "\n")
        try append(url, claudeLine("2026-07-02T09:00:00.000Z", input: 10, output: 2) + "\n")

        let incremental = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: first))
        let full = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))

        #expect(incremental.tokens == full.tokens)
        #expect(incremental.tokens == 187)
        #expect(incremental.projects == full.projects)
        #expect(incremental.size == full.size)
    }

    @Test("appending to a Codex rollout resumes from the cached cumulative total")
    func codexIncrementalResumes() throws {
        let url = try tempFile("rollout-z.jsonl", [
            codexMeta("2026-07-01T09:00:00.000Z"),
            codexLine("2026-07-01T10:00:00.000Z", cumulative: 100),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Codex", cached: nil))
        #expect(first.tokens == 100)

        // Without carrying the cursor, this next cumulative value of 250 would be
        // read as 250 of new work instead of 150.
        try append(url, codexLine("2026-07-01T11:00:00.000Z", cumulative: 250) + "\n")

        let incremental = try #require(AgentSessionReader.row(for: url, agent: "Codex", cached: first))
        let full = try #require(AgentSessionReader.row(for: url, agent: "Codex", cached: nil))
        #expect(incremental.tokens == 250)
        #expect(incremental.tokens == full.tokens)
        #expect(incremental.projects == full.projects)
    }

    @Test("a half-written trailing line is left for the next pass")
    func partialLineIsNotConsumed() throws {
        // The agent is mid-write: the last line has no newline yet. Parsing it
        // would drop the record; the reader must wait for the writer to finish.
        let complete = claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 20) + "\n"
        let url = try tempFile("session.jsonl", complete + "{\"type\":\"assis")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(first.tokens == 120)
        #expect(first.size == complete.utf8.count)      // stopped at the last newline

        // The writer finishes that line; its tokens now count, exactly once.
        try append(url, "tant\",\"timestamp\":\"2026-07-01T10:05:00.000Z\",\"cwd\":\"/tmp/proj\"," +
                   "\"message\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":3}}}\n")
        let second = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: first))
        #expect(second.tokens == 130)
    }

    @Test("a rewritten or truncated file is re-parsed from scratch")
    func truncatedFileReparses() throws {
        let url = try tempFile("session.jsonl", [
            claudeLine("2026-07-01T10:00:00.000Z", input: 100, output: 20),
            claudeLine("2026-07-01T11:00:00.000Z", input: 100, output: 20),
            ""
        ].joined(separator: "\n"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(first.tokens == 240)

        // Shrink it — the cached offset now points past EOF.
        try claudeLine("2026-07-01T10:00:00.000Z", input: 5, output: 1)
            .appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let second = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: first))
        #expect(second.tokens == 6)          // reparsed, not folded onto the old total
    }

    @Test("an empty transcript yields nothing rather than a phantom session")
    func emptyFile() throws {
        let url = try tempFile("session.jsonl", "")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let row = try #require(AgentSessionReader.row(for: url, agent: "Claude Code", cached: nil))
        #expect(row.tokens == 0)
    }

    // MARK: - Session windows

    @Test("session spans cover their own events")
    func sessionCovers() {
        let session = AgentSession(agent: "Codex", project: "/tmp/p", start: 100, end: 200, tokens: 5)
        #expect(session.covers(100))
        #expect(session.covers(150))
        #expect(session.covers(200))
        #expect(!session.covers(99))
        #expect(!session.covers(201))
    }

    // MARK: - Cache round-trip

    @Test("the day map survives a round-trip through the cache")
    func cacheRoundTrip() throws {
        let store = try UsageStore(path: ":memory:")
        let row = SessionCacheRow(
            path: "/tmp/a.jsonl", agent: "Claude Code", mtime: 123, size: 456,
            cursor: 42, lastProject: "/tmp/proj",
            projects: ["/tmp/proj": SessionProjectUsage(
                tokens: 789, start: 1, end: 2, days: ["2026-07-01": 500, "2026-07-02": 289])])
        try store.upsertSessionCache([row])

        let back = try #require(store.sessionCache()["/tmp/a.jsonl"])
        #expect(back.tokens == 789)
        #expect(back.cursor == 42)
        #expect(back.lastProject == "/tmp/proj")
        #expect(back.projects == row.projects)

        // Re-upserting the same path updates rather than duplicating.
        var updated = row
        updated.projects["/tmp/proj"]?.tokens = 1000
        try store.upsertSessionCache([updated])
        #expect(store.sessionCache().count == 1)
        #expect(store.sessionCache()["/tmp/a.jsonl"]?.tokens == 1000)
    }

    @Test("cache rows for deleted transcripts are pruned")
    func prunesDeadRows() throws {
        let store = try UsageStore(path: ":memory:")
        try store.upsertSessionCache([
            SessionCacheRow(path: "/tmp/live.jsonl", agent: "Codex", mtime: 1, size: 1,
                            projects: ["/p": SessionProjectUsage(tokens: 1)]),
            SessionCacheRow(path: "/tmp/gone.jsonl", agent: "Codex", mtime: 1, size: 1,
                            projects: ["/p": SessionProjectUsage(tokens: 1)])
        ])
        store.pruneSessionCache(keeping: ["/tmp/live.jsonl"])
        let remaining = store.sessionCache()
        #expect(remaining.count == 1)
        #expect(remaining["/tmp/live.jsonl"] != nil)
    }
}
