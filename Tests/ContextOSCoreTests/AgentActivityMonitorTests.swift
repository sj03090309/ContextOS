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

    func testPendingToolCallWithinCapStaysActive() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A genuinely long tool: unanswered for 10 minutes, still under the cap.
        try writeLog(home, ".claude/projects/-Users-me-app/s.jsonl",
                     lines: [toolUseLine], mtime: Date(timeIntervalSinceNow: -600))

        XCTAssertTrue(AgentActivityMonitor(home: home).isActive(within: 20))
    }

    func testPendingToolCallExpiresAfterCap() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Unanswered tool call, but quiet for 20 minutes — the agent likely died
        // mid-tool; the cap stops the mascot from staying on forever.
        try writeLog(home, ".claude/projects/-Users-me-app/s.jsonl",
                     lines: [toolUseLine], mtime: Date(timeIntervalSinceNow: -1200))

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

    // MARK: - Codex format (response_item / call_id)

    private let codexCallLine = #"{"type":"response_item","payload":{"type":"function_call","id":"fc_1","call_id":"call_ABC","name":"shell","arguments":"{}"}}"#
    private let codexOutputLine = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"call_ABC","output":"done"}}"#
    private let codexCustomCallLine = #"{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_XYZ","name":"apply_patch","input":""}}"#
    private let codexCustomOutputLine = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_XYZ","output":"ok"}}"#

    func testCodexUnansweredFunctionCallIsPending() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("rollout-pending.jsonl")
        try (codexCallLine + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(AgentActivityMonitor.hasPendingToolCall(url))
    }

    func testCodexAnsweredFunctionCallIsNotPending() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("rollout-done.jsonl")
        try ([codexCallLine, codexCustomCallLine, codexOutputLine, codexCustomOutputLine]
            .joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertFalse(AgentActivityMonitor.hasPendingToolCall(url))
    }

    func testCodexLongToolKeepsActiveDespiteQuietLog() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // A Codex tool (e.g. a long build) in flight, log quiet for 2 minutes.
        try writeLog(home, ".codex/sessions/2026/07/13/rollout-x.jsonl",
                     lines: [codexCallLine], mtime: Date(timeIntervalSinceNow: -120))
        XCTAssertTrue(AgentActivityMonitor(home: home).isActive(within: 20))
    }

    // MARK: - Event-driven updates

    func testNoteWriteTracksTheNewestSessionLog() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let monitor = AgentActivityMonitor(home: home)
        let older = ".claude/projects/-Users-me-app/a.jsonl"
        let newer = ".codex/sessions/2026/07/13/rollout-b.jsonl"
        try write(home, older, mtime: Date(timeIntervalSinceNow: -60))
        try write(home, newer, mtime: Date(timeIntervalSinceNow: -5))

        XCTAssertTrue(monitor.noteWrite(atPath: home.appendingPathComponent(newer).path))
        XCTAssertTrue(monitor.noteWrite(atPath: home.appendingPathComponent(older).path))
        // The older write arriving second does not unseat the newer log.
        XCTAssertEqual(monitor.newestLog?.url.lastPathComponent, "rollout-b.jsonl")

        // Written again: now it is the newest.
        try write(home, older)
        monitor.noteWrite(atPath: home.appendingPathComponent(older).path)
        XCTAssertEqual(monitor.newestLog?.url.lastPathComponent, "a.jsonl")
    }

    func testNoteWriteIgnoresWhatTheScanWouldIgnore() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let monitor = AgentActivityMonitor(home: home)
        for relative in [".claude/projects/-Users-me-app/session/subagents/agent-1.jsonl",
                         ".claude/projects/-Users-me-app/notes.txt",
                         ".claude/todos/x.jsonl"] {
            try write(home, relative)
            XCTAssertFalse(monitor.noteWrite(atPath: home.appendingPathComponent(relative).path),
                           relative)
        }
        XCTAssertNil(monitor.newestLog)
        // A path that no longer exists (deleted between the event and the stat).
        XCTAssertFalse(monitor.noteWrite(
            atPath: home.appendingPathComponent(".claude/projects/-x/gone.jsonl").path))
    }

    func testRescanFindsTheNewestLogForEvents() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(home, ".claude/projects/-Users-me-app/a.jsonl", mtime: Date(timeIntervalSinceNow: -30))
        try write(home, ".claude/projects/-Users-me-app/b.jsonl", mtime: Date(timeIntervalSinceNow: -3))
        let monitor = AgentActivityMonitor(home: home)
        XCTAssertNil(monitor.newestLog)
        monitor.rescan()
        XCTAssertEqual(monitor.newestLog?.url.lastPathComponent, "b.jsonl")
    }

    func testPendingToolCallSurvivesATailCutMidCharacter() throws {
        // The tail read starts at an arbitrary byte. Cutting a multi-byte
        // character in half used to make the whole tail undecodable, so a
        // Korean-heavy log reported no pending call at all.
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = home.appendingPathComponent("korean.jsonl")
        let chatter = #"{"type":"user","message":{"role":"user","content":"한글 한글 한글 한글"}}"#
        let body = Array(repeating: chatter, count: 50).joined(separator: "\n") + "\n" + toolUseLine + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        let size = body.utf8.count
        // A tail length whose first byte falls inside a 3-byte Hangul character.
        var tail = size - 40
        while tail > 0 {
            let first = Array(body.utf8)[size - tail]
            if first & 0xC0 == 0x80 { break }       // a continuation byte
            tail -= 1
        }
        XCTAssertTrue(AgentActivityMonitor.hasPendingToolCall(url, tailBytes: tail))
    }

    func testFileEventStreamReportsSessionLogWrites() throws {
        // End to end through real FSEvents: a write to a session log reaches the
        // monitor as its newest log, with no scan. The temp dir sits behind the
        // /var → /private/var symlink, so this also covers the stream reporting
        // real paths that don't textually match `home`.
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects/-Users-me-app"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        let monitor = AgentActivityMonitor(home: home)

        let seen = expectation(description: "session log write reported")
        seen.assertForOverFulfill = false
        let stream = FileEventStream(paths: monitor.watchRoots.map(\.path), latency: 0.1) { events in
            for event in events where monitor.noteWrite(atPath: event.path) { seen.fulfill() }
        }
        XCTAssertTrue(stream.start())
        defer { stream.stop() }

        // Give the stream a moment to arm, then write.
        Thread.sleep(forTimeInterval: 0.3)
        try write(home, ".claude/projects/-Users-me-app/live.jsonl")
        wait(for: [seen], timeout: 10)
        XCTAssertEqual(monitor.newestLog?.url.lastPathComponent, "live.jsonl")
    }
}
