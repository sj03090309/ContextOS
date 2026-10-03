import Foundation
import Testing
@testable import ContextOSCore

@Suite("Session activity lifecycle")
struct SessionActivityTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_791_007_200)
    private func at(_ seconds: Double) -> Date { now.addingTimeInterval(seconds) }

    private func stamp(_ seconds: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: at(seconds))
    }
    private func claude(_ seconds: Double, type: String = "assistant", content: Any,
                        stop: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["content": content]
        if let stop { message["stop_reason"] = stop }
        return ["type": type, "timestamp": stamp(seconds), "cwd": "/tmp/ERPproject", "message": message]
    }
    private func begin(_ seconds: Double) -> [String: Any] {
        claude(seconds, type: "user", content: "Implement the next screen")
    }
    private func call(_ seconds: Double, name: String = "Bash", id: String = "tool_1") -> [String: Any] {
        claude(seconds, content: [["type": "tool_use", "id": id, "name": name]], stop: "tool_use")
    }
    private func result(_ seconds: Double, id: String = "tool_1") -> [String: Any] {
        claude(seconds, type: "user", content: [["type": "tool_result", "tool_use_id": id, "content": "done"]])
    }
    private func state(_ objects: [[String: Any]]) -> SessionTurnState {
        var state = SessionTurnState()
        for obj in objects { SessionActivityTracker.consume(obj, state: &state, now: now) }
        return state
    }
    private func status(_ objects: [[String: Any]], time: Date? = nil) -> SessionActivityStatus {
        state(objects).status(session: "s", agent: "Claude Code", now: time ?? now)
    }

    @Test("Reported 78-second reasoning gap is waiting, without an invented end")
    func reasoningGap() {
        let s = status([begin(-1000), result(-81), claude(-78, content: [], stop: "tool_use")])
        #expect(s.phase == .waiting)
        #expect(s.startedAt == at(-1000))
        #expect(s.endedAt == nil)
        #expect(s.pendingTools == 0)
    }

    @Test("A returned tool continues the turn until the assistant actually ends it")
    func answeredTool() {
        let s = status([begin(-200), call(-130), result(-120)])
        #expect(s.phase == .waiting)
        #expect(s.pendingTools == 0)
    }

    @Test("A tool longer than fifteen minutes remains pending, independently of savings")
    func longTool() {
        let s = status([begin(-1800), call(-1100, name: "mcp__contextos__read_optimized")])
        #expect(s.phase == .waiting)
        #expect(s.pendingTools == 1)
        #expect(s.optimizing)
        #expect(s.endedAt == nil)
    }

    @Test("An abandoned turn becomes unknown, never completed or permanently working")
    func abandonedTurn() {
        let s = status([begin(-8000), call(-7200)])
        #expect(s.phase == .unknown)
        #expect(s.endedAt == nil)
        #expect(s.recheckAt == nil)
        #expect(!s.optimizing)
    }

    @Test("Completion keeps its real timestamp despite later metadata and stale replay")
    func actualCompletion() {
        var s = state([begin(-300), call(-150), result(-100), claude(-90, content: "Done", stop: "end_turn")])
        s.apply(.activity, at: at(-80), now: now)
        s.apply(.started, at: at(-400), now: now)
        s.apply(.toolStarted("old", "Bash"), at: at(-200), now: now)
        let v = s.status(session: "s", agent: "Claude Code", now: now)
        #expect(v.phase == .completed)
        #expect(v.endedAt == at(-90))
        #expect(v.pendingTools == 0)
    }

    @Test("User interruption clears the pending tool without claiming completion")
    func interrupted() {
        let s = status([begin(-100), call(-80), claude(-60, type: "user", content: "[Request interrupted by user for tool use]")])
        #expect(s.phase == .interrupted)
        #expect(s.endedAt == at(-60))
        #expect(s.pendingTools == 0)
    }

    @Test("Token-limit termination is reported as interrupted")
    func tokenLimit() {
        #expect(status([begin(-80), claude(-5, content: "partial", stop: "max_tokens")]).phase == .interrupted)
    }

    @Test("A duplicate start does not erase an unanswered call")
    func duplicateStart() {
        var s = state([begin(-100), call(-60)])
        s.apply(.started, at: at(-100), now: now)
        #expect(s.status(session: "s", agent: "Claude Code", now: now).pendingTools == 1)
    }

    @Test("A genuine next turn reopens only that session")
    func nextTurn() {
        let s = status([begin(-500), claude(-400, content: "Done", stop: "end_turn"), begin(-10)])
        #expect(s.phase == .working)
        #expect(s.startedAt == at(-10))
        #expect(s.endedAt == nil)
    }

    @Test("Quiet/stale boundaries have finite rechecks", arguments: [19.0, 20.0, 3599.0, 3600.0])
    func boundaries(_ age: Double) {
        let s = status([begin(-age)])
        #expect(s.phase == (age < 20 ? .working : age < 3600 ? .waiting : .unknown))
        #expect(s.recheckAt == (age < 20 ? at(20-age) : age < 3600 ? at(3600-age) : nil))
        #expect(s.endedAt == nil)
    }

    @Test("Relaunch recovers work even when the original prompt is outside the tail")
    func tailRecovery() {
        let s = status([claude(-78, content: [], stop: "tool_use")])
        #expect(s.phase == .waiting)
        #expect(s.startedAt == nil)
        #expect(s.endedAt == nil)
    }

    @Test("Midnight does not end a turn")
    func midnight() {
        var s = SessionTurnState()
        let start = TimeKeys.epoch(fromISO8601: "2026-10-02T23:59:50+09:00")!
        let current = Date(timeIntervalSince1970: start + 78)
        SessionActivityTracker.consume(["type": "user", "timestamp": "2026-10-02T23:59:50+09:00",
            "message": ["content": "Continue the implementation"]], state: &s, now: current)
        let v = s.status(session: "s", agent: "Claude Code", now: current)
        #expect(v.phase == .waiting)
        #expect(v.startedAt == Date(timeIntervalSince1970: start))
        #expect(v.endedAt == nil)
    }

    @Test("Codex lifecycle and tool IDs are scoped to their own turn")
    func codexLifecycle() {
        func event(_ seconds: Double, _ payload: [String: Any], type: String = "event_msg") -> [String: Any] {
            ["type": type, "timestamp": stamp(seconds), "payload": payload]
        }
        var s = state([event(-300, ["type": "task_started"]),
            event(-200, ["type": "function_call", "call_id": "call_a", "name": "shell"], type: "response_item"),
            event(-90, ["type": "function_call_output", "call_id": "call_a"], type: "response_item")])
        #expect(s.status(session: "s", agent: "Codex", now: now).phase == .waiting)
        SessionActivityTracker.consume(event(-30, ["type": "turn_aborted"]), state: &s, now: now)
        #expect(s.phase == .interrupted)
        SessionActivityTracker.consume(event(-20, ["type": "task_started"]), state: &s, now: now)
        SessionActivityTracker.consume(event(-1, ["type": "task_complete"]), state: &s, now: now)
        #expect(s.phase == .completed)
        #expect(s.endedAt == at(-1))
    }

    private func withLogs(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-turn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func write(_ objects: [[String: Any]], to url: URL) throws {
        let data = try objects.reduce(into: Data()) { result, object in
            result.append(try JSONSerialization.data(withJSONObject: object)); result.append(10)
        }
        try data.write(to: url)
    }
    private func logs(_ urls: [URL]) throws -> [(url: URL, mtime: Date)] {
        try urls.map { ($0, try FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as! Date) }
    }

    @Test("A newer completed session cannot conceal an older active session")
    func simultaneousSessions() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
            try write([begin(-500), call(-100)], to: a)
            try write([begin(-200), claude(-1, content: "Done", stop: "end_turn")], to: b)
            let snapshot = SessionActivityTracker().snapshot(logs: try logs([a,b]), now: now)
            #expect(snapshot.activeSessions == 1)
            #expect(snapshot.selected?.session == a.path)
            #expect(snapshot.selected?.phase == .waiting)
        }
    }

    @Test("Distinct sessions can use identical call IDs without cancelling each other")
    func callIDsArePerSession() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
            try write([begin(-500), call(-100, name: "mcp__contextos__read_optimized")], to: a)
            try write([begin(-200), call(-150), result(-50), claude(-1, content: "Done", stop: "end_turn")], to: b)
            let snapshot = SessionActivityTracker().snapshot(logs: try logs([a,b]), now: now)
            #expect(snapshot.activeSessions == 1)
            #expect(snapshot.optimizing)
            #expect(snapshot.selected?.pendingTools == 1)
        }
    }

    @Test("Planning and content optimization are separate from AI turn state")
    func planningVsOptimization() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            try write([begin(-30), call(-10, name: "mcp__contextos__get_relevant_context")], to: a)
            let v = SessionActivityTracker().snapshot(logs: try logs([a]), now: now)
            #expect(v.planning)
            #expect(!v.optimizing)
            #expect(v.activeSessions == 1)
        }
    }

    @Test("Partial JSON is resumed only once it has a complete line")
    func partialAppend() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            try write([begin(-100), call(-60)], to: a)
            let tracker = SessionActivityTracker()
            #expect(tracker.snapshot(logs: try logs([a]), now: now).activeSessions == 1)
            let end = try JSONSerialization.data(withJSONObject: claude(-1, content: "Done", stop: "end_turn"))
            let handle = try FileHandle(forWritingTo: a)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: end)
            #expect(tracker.snapshot(logs: try logs([a]), now: now).activeSessions == 1)
            try handle.write(contentsOf: Data([10]))
            let completed = tracker.snapshot(logs: try logs([a]), now: now)
            #expect(completed.activeSessions == 0)
            #expect(completed.selected?.endedAt == at(-1))
        }
    }

    @Test("Relaunch and replay agree; truncated/replaced logs are parsed afresh")
    func replayAndReplacement() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            let tracker = SessionActivityTracker()
            try write([begin(-100), call(-60), result(-50)], to: a)
            let first = tracker.snapshot(logs: try logs([a]), now: now)
            #expect(first == tracker.snapshot(logs: try logs([a]), now: now))
            #expect(first == SessionActivityTracker().snapshot(logs: try logs([a]), now: now))
            try write([claude(-1, content: "Done", stop: "end_turn")], to: a)
            #expect(tracker.snapshot(logs: try logs([a]), now: now).selected?.phase == .completed)
        }
    }

    @Test("Missing timestamps and missing logs remain unknown")
    func insufficientEvidence() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            try write([["type": "assistant", "message": ["stop_reason": "end_turn"]]], to: a)
            let tracker = SessionActivityTracker()
            let v = tracker.snapshot(logs: try logs([a]), now: now)
            #expect(v.selected?.phase == .unknown)
            #expect(v.selected?.endedAt == nil)
            try FileManager.default.removeItem(at: a)
            #expect(tracker.snapshot(logs: [(a, now)], now: now).selected?.phase == .unknown)
        }
    }

    @Test("Future timestamps cannot pin a turn working")
    func futureTimestamp() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            try write([begin(7200)], to: a)
            let v = SessionActivityTracker().snapshot(logs: try logs([a]), now: now)
            #expect(v.activeSessions == 0)
            #expect(v.selected?.phase == .unknown)
        }
    }

    @Test("A completed call replayed at the completion timestamp stays completed")
    func sameTimestampReplay() {
        var s = state([begin(-100), claude(-10, content: "Done", stop: "end_turn")])
        s.apply(.toolStarted("old", "Bash"), at: at(-10), now: now)
        s.apply(.started, at: at(-10), now: now)
        #expect(s.phase == .completed)
        #expect(s.endedAt == at(-10))
    }

    @Test("Two path spellings of one session never count as two agents")
    func symlinkReplay() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl"), alias = root.appendingPathComponent("alias.jsonl")
            try write([begin(-100), call(-60)], to: a)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: a)
            let v = SessionActivityTracker().snapshot(logs: try logs([a,alias]), now: now)
            #expect(v.activeSessions == 1)
        }
    }

    @Test("A late filesystem event does not discard an already-read turn start")
    func delayedFileEvent() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl")
            try write([begin(-100), call(-60)], to: a)
            let tracker = SessionActivityTracker(bootstrapBytes: 256)
            let oldMetadata = try logs([a])
            _ = tracker.snapshot(logs: oldMetadata, now: now)
            let handle = try FileHandle(forWritingTo: a)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let obj = claude(-1, content: String(repeating: "reasoning", count: 100))
            var data = try JSONSerialization.data(withJSONObject: obj); data.append(10)
            try handle.write(contentsOf: data)
            let immediate = tracker.snapshot(logs: oldMetadata, now: now)
            let delayed = tracker.snapshot(logs: try logs([a]), now: now)
            #expect(immediate == delayed)
        }
    }

    @Test("Two active sessions remain independent when one completes")
    func independentCompletion() throws {
        try withLogs { root in
            let a = root.appendingPathComponent("a.jsonl"), b = root.appendingPathComponent("b.jsonl")
            try write([begin(-100), call(-60)], to: a)
            try write([begin(-50), call(-30)], to: b)
            let tracker = SessionActivityTracker()
            #expect(tracker.snapshot(logs: try logs([a,b]), now: now).activeSessions == 2)
            try write([begin(-50), claude(-1, content: "Done", stop: "end_turn")], to: b)
            let v = tracker.snapshot(logs: try logs([a,b]), now: now)
            #expect(v.activeSessions == 1)
            #expect(v.selected?.session == a.path)
        }
    }
}
