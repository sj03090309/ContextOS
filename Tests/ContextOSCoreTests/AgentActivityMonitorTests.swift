import XCTest
@testable import ContextOSCore

final class AgentActivityMonitorTests: XCTestCase {

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ home: URL, _ relative: String, mtime: Date? = nil) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    func testFreshClaudeSessionLogMeansActive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/projects/-Users-me-app/session-abc.jsonl")   // just written

        XCTAssertTrue(AgentActivityMonitor(home: home).isActive(within: 6))
    }

    func testStaleLogMeansIdle() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/projects/-Users-me-app/session-abc.jsonl",
                  mtime: Date(timeIntervalSinceNow: -300))   // 5 minutes quiet

        XCTAssertFalse(AgentActivityMonitor(home: home).isActive(within: 6))
    }

    func testFreshCodexSessionLogMeansActive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".codex/sessions/2026/07/11/rollout-2026-07-11.jsonl")

        XCTAssertTrue(AgentActivityMonitor(home: home).isActive(within: 6))
    }

    func testNoLogsAtAllMeansIdle() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertFalse(AgentActivityMonitor(home: home).isActive(within: 6))
    }

    func testActivityAfterQuietIsCaughtOnRescan() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let monitor = AgentActivityMonitor(home: home)
        XCTAssertFalse(monitor.isActive(within: 6))   // quiet, scan happened

        // A new command arrives (session file touched). The next check runs
        // 4s+ after the last scan, so pass a shifted `now` to allow the rescan.
        try write(home, ".claude/projects/-Users-me-app/session-new.jsonl")
        XCTAssertTrue(monitor.isActive(within: 6, now: Date(timeIntervalSinceNow: 4.5)))
    }

    // MARK: - Long-running tool (pending tool call) detection

    /// Writes jsonl `lines` to a session log and stamps its mtime.
    private func writeLog(_ home: URL, _ relative: String, lines: [String], mtime: Date) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private let toolUseLine = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{}}]}}"#
    private let toolResultLine = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"done"}]}}"#

    func testUnansweredToolCallKeepsActiveDespiteQuietLog() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Last event is a tool_use with no matching result: a long build is
        // running now. Log has been quiet for 90s — past the 20s window.
        try writeLog(home, ".claude/projects/-Users-me-app/s.jsonl",
                     lines: [toolUseLine], mtime: Date(timeIntervalSinceNow: -90))

        XCTAssertTrue(AgentActivityMonitor(home: home).isActive(within: 20))
    }

    func testAnsweredToolCallGoesIdleWhenLogQuiet() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // The tool already returned (result present) and the log is quiet — the
        // agent is idle, not mid-tool.
        try writeLog(home, ".claude/projects/-Users-me-app/s.jsonl",
                     lines: [toolUseLine, toolResultLine], mtime: Date(timeIntervalSinceNow: -90))

        XCTAssertFalse(AgentActivityMonitor(home: home).isActive(within: 20))
    }

    func testPendingToolCallExpiresAfterCap() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Unanswered tool call, but quiet for 10 minutes — the agent likely died
        // mid-tool; the cap stops the mascot from staying on forever.
        try writeLog(home, ".claude/projects/-Users-me-app/s.jsonl",
                     lines: [toolUseLine], mtime: Date(timeIntervalSinceNow: -600))

        XCTAssertFalse(AgentActivityMonitor(home: home).isActive(within: 20))
    }

    func testHasPendingToolCallMatchesIdsAcrossLines() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("pending.jsonl")
        try (toolUseLine + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(AgentActivityMonitor.hasPendingToolCall(url))

        let resolved = home.appendingPathComponent("resolved.jsonl")
        try ([toolUseLine, toolResultLine].joined(separator: "\n") + "\n")
            .write(to: resolved, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentActivityMonitor.hasPendingToolCall(resolved))
    }
}
