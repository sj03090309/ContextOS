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
}
