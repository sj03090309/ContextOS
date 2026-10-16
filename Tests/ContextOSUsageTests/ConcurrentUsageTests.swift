import Foundation
import Testing
@testable import ContextOSCore
import ContextOSUsage

@Suite struct ConcurrentUsageTests {
    let now = ISO8601DateFormatter().date(from: "2025-10-12T00:30:00Z")! // fixed 2025-10-12 UTC
    func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func write(_ lines: [[String: Any]], _ relative: String, home: URL) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for line in lines { data.append(try JSONSerialization.data(withJSONObject: line, options: .sortedKeys)); data.append(10) }
        try data.write(to: url); return url
    }
    func stamp(_ seconds: Double = 0) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)) }
    func meta(_ id: String, model: String = "gpt-test") -> [[String: Any]] {
        [["type":"session_meta", "timestamp":stamp(-100), "payload":["id":id,"cwd":"/private/project"]],
         ["type":"turn_context", "timestamp":stamp(-90), "payload":["model":model]]]
    }
    func counter(_ total: Int, _ seconds: Double = -10) -> [String: Any] {
        ["type":"event_msg", "timestamp":stamp(seconds), "payload":["type":"token_count", "info":["total_token_usage":["total_tokens":total,"input_tokens":total,"cached_input_tokens":total,"output_tokens":0]]]]
    }
    func phase(_ type: String, _ seconds: Double = -5) -> [String: Any] {
        ["type":"event_msg", "timestamp":stamp(seconds), "payload":["type":type]]
    }
    func claude(_ id: String = "message-1", output: Int = 20, seconds: Double = -5) -> [String: Any] {
        ["type":"assistant", "sessionId":"claude-1", "timestamp":stamp(seconds), "cwd":"/private/project",
         "message":["id":id,"model":"claude-test","stop_reason":"end_turn", "content":[["type":"text","text":"SECRET PROMPT NEVER DECODE"]],
                    "usage":["input_tokens":100,"output_tokens":output,"cache_read_input_tokens":50,"cache_creation_input_tokens":30]]]
    }
    @Test func simultaneousSessionsAndToolTotals() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        _ = try write(meta("a") + [counter(100), phase("task_started")], ".codex/sessions/rollout-a.jsonl", home:h)
        _ = try write(meta("b") + [counter(300), phase("task_complete")], ".codex/sessions/rollout-b.jsonl", home:h)
        _ = try write([claude()], ".claude/projects/project/a.jsonl", home:h)
        let s = ConcurrentUsageReader().snapshot(home:h, now:now, timeZone:.gmt)
        #expect(s.sessions.count == 3)
        #expect(s.sessions.filter { $0.state == .working }.count == 1)
        #expect(s.sessions.filter { $0.state == .idle }.count == 2)
        #expect(s.widget.today == 600)
        #expect(s.widget.agents.first { $0.name == "Codex" }?.tokens == 400)
        #expect(s.widget.models.reduce(0) { $0 + $1.tokens } == 600)
    }
    @Test func codexCacheSubsetDuplicateResetAndReplay() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let c = counter(5, -3)
        _ = try write(meta("a") + [counter(100,-8),counter(100,-7),counter(130,-6),c,counter(8,-2),c], ".codex/sessions/rollout-a.jsonl",home:h)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == 138) // Cached input is already inside total_tokens.
    }
    @Test func unorderedEqualTimestampFragmentsDoNotInventAReset() throws {
        let h=try home(); defer { try? FileManager.default.removeItem(at:h) }
        _=try write(meta("fragment")+[counter(999)],".codex/sessions/rollout-a.jsonl",home:h)
        _=try write(meta("fragment")+[counter(1000)],".codex/sessions/rollout-b.jsonl",home:h)
        let value=ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(value.widget.today == 1000)
        #expect(value.widget.providers.first?.state == .partial)
    }
    @Test func equalTimestampCounterOrderSurvivesDecimalGrowthResetAndShortCopy() throws {
        for (first,second,expected) in [(999,1000,1000),(1000,10,1010)] {
            let h=try home(); defer { try? FileManager.default.removeItem(at:h) }
            let lines=meta("equal-time")+[counter(first),counter(second)]
            _=try write(lines,".codex/sessions/rollout-full.jsonl",home:h)
            _=try write(meta("equal-time")+[counter(second)],".codex/sessions/rollout-short.jsonl",home:h)
            let value=ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
            #expect(value.widget.today == Int64(expected))
        }
    }
    @Test func syntheticClaudeZeroIsMissingRatherThanObservedZero() throws {
        let h=try home(); defer { try? FileManager.default.removeItem(at:h) }
        var synthetic=claude()
        var message=synthetic["message"] as! [String:Any]
        message["model"]="<synthetic>"; message["usage"]=["input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0]
        synthetic["message"]=message
        _=try write([synthetic],".claude/projects/p/a.jsonl",home:h)
        let value=ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(value.widget.today == nil && value.widget.models.isEmpty)
        #expect(value.widget.providers.first { $0.name == "Claude Code" }?.state == .partial)
        // A real model's explicit zero is still an observed zero.
        message["model"]="claude-real-zero"; synthetic["message"]=message
        _=try write([synthetic],".claude/projects/p/b.jsonl",home:h)
        #expect(ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt).widget.today == 0)
    }
    @Test func syntheticClaudeRecordDoesNotReplaceRealModelOrAccounting() throws {
        let h=try home(); defer { try? FileManager.default.removeItem(at:h) }
        var synthetic=claude("placeholder",output:0)
        var message=synthetic["message"] as! [String:Any]
        message["model"]="<synthetic>"; message["usage"]=["input_tokens":0,"output_tokens":0]
        synthetic["message"]=message
        _=try write([claude(seconds:-6),synthetic],".claude/projects/p/a.jsonl",home:h)
        let value=ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(value.widget.today == 200)
        #expect(value.widget.models.allSatisfy { !$0.name.contains("synthetic") })
        #expect(value.sessions.first?.model == "claude-test")
    }
    @Test func claudeCachedInputDisjointAndStreamingMessageReplacement() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write([claude(output:10),claude(output:20),claude(output:20)], ".claude/projects/project/a.jsonl",home:h)
        #expect(ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt).widget.today == 200)
    }
    @Test func duplicatedTranscriptIsOneSessionAndOneTotal() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let lines = meta("a") + [counter(100), phase("task_started")]
        _ = try write(lines,".codex/sessions/rollout-a.jsonl",home:h)
        _ = try write(lines,".codex/sessions/rollout-copy.jsonl",home:h)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == 100); #expect(s.sessions.count == 1)
    }
    @Test func copiedClaudeUpdatesAndCodexPartialCopiesMergeBySession() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write([claude(output:10)], ".claude/projects/project/a.jsonl",home:h)
        _ = try write([claude(output:20)], ".claude/projects/project/copy.jsonl",home:h)
        _ = try write(meta("a") + [counter(100,-20)], ".codex/sessions/rollout-a.jsonl",home:h)
        _ = try write(meta("a") + [counter(130,-10)], ".codex/sessions/rollout-copy.jsonl",home:h)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == 330)
        #expect(s.sessions.count == 2)
    }
    @Test func DSTCalendarHasSevenLocalDaysAndModelChangesPreserveTotal() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        var lines = meta("a", model:"first-model") + [counter(100,-20)]
        lines += [["type":"turn_context","timestamp":stamp(-15),"payload":["model":"second-model"]],counter(150,-10)]
        _ = try write(lines,".codex/sessions/rollout-a.jsonl",home:h)
        let reader = ConcurrentUsageReader()
        let s = reader.snapshot(home:h,now:now,timeZone:TimeZone(identifier:"Asia/Seoul")!)
        #expect(s.widget.models.first { $0.name.contains("first-model") }?.tokens == 100)
        #expect(s.widget.models.first { $0.name.contains("second-model") }?.tokens == 50)
        let dst = ISO8601DateFormatter().date(from:"2026-11-02T12:00:00Z")!
        let series = reader.snapshot(home:h,now:dst,timeZone:TimeZone(identifier:"America/Los_Angeles")!).widget.days
        #expect(series.count == 7)
        #expect(series.last!.date.timeIntervalSince(series[5].date) == 25 * 3600)
    }
    @Test func staleAtMidnightAndDamagedSharedSnapshot() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let date = Calendar.current.startOfDay(for:Date()).addingTimeInterval(-1)
        let snapshot = WidgetUsageSnapshot(generatedAt:date, timeZoneID:TimeZone.current.identifier)
        #expect(snapshot.stale(at:date.addingTimeInterval(2)))
        try Data("{broken".utf8).write(to:h.appendingPathComponent(WidgetSnapshotStore.fileName))
        #expect(WidgetSnapshotStore.read(from:h) == nil)
    }
    @Test func zeroMissingAndUnavailableAreDistinct() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let reader = ConcurrentUsageReader()
        let empty = reader.snapshot(home:h,now:now,timeZone:.gmt)
        #expect(empty.widget.today == nil)
        #expect(empty.widget.providers.first?.state == .noRecords)
        _ = try write(meta("a") + [counter(0)],".codex/sessions/rollout-a.jsonl",home:h)
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 0)
        let deniedRoot = h.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at:deniedRoot.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data().write(to:deniedRoot)
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.providers.first { $0.name == "Claude Code" }?.state == .unavailable)
    }
    @Test func revokedPermissionDoesNotReuseCachedSuccess() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let file = try write(meta("a") + [counter(100)],".codex/sessions/rollout-a.jsonl",home:h)
        let reader = ConcurrentUsageReader()
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 100)
        try FileManager.default.setAttributes([.posixPermissions:0o000],ofItemAtPath:file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
        let denied = reader.snapshot(home:h,now:now,timeZone:.gmt)
        #expect(denied.widget.today == nil)
        #expect(denied.widget.providers.first?.state == .partial)
    }
    @Test func quietTurnDoesNotBecomeIdleAndMtimeDoesNotInventWork() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write(meta("a") + [phase("task_started", -60)],".codex/sessions/rollout-a.jsonl",home:h)
        let reader = ConcurrentUsageReader()
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).sessions.first?.state == .waiting)
        #expect(reader.snapshot(home:h,now:now.addingTimeInterval(3600),timeZone:.gmt).sessions.first?.state == .unknown)
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == nil)
    }
    @Test func incompleteLineAndFileReplacementDoNotDoubleCount() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let file = try write(meta("a") + [counter(100)],".codex/sessions/rollout-a.jsonl",home:h)
        let reader = ConcurrentUsageReader()
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 100)
        let data = try JSONSerialization.data(withJSONObject:counter(120,-1))
        let handle = try FileHandle(forWritingTo:file); try handle.seekToEnd(); try handle.write(contentsOf:data.prefix(data.count/2)); try handle.close()
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 100)
        let tail = try FileHandle(forWritingTo:file); try tail.seekToEnd(); try tail.write(contentsOf:data.suffix(data.count-data.count/2)); try tail.write(contentsOf:Data([10])); try tail.close()
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 120)
        try FileManager.default.removeItem(at:file)
        _ = try write(meta("restarted") + [counter(7)],".codex/sessions/rollout-a.jsonl",home:h)
        #expect(reader.snapshot(home:h,now:now,timeZone:.gmt).widget.today == 7)
    }
    @Test func timeZoneChangeRebucketsWithoutReadingAgain() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write(meta("a") + [counter(100,-3600)],".codex/sessions/rollout-a.jsonl",home:h)
        let reader = ConcurrentUsageReader()
        let utc = reader.snapshot(home:h,now:now,timeZone:.gmt)
        let seoul = reader.snapshot(home:h,now:now,timeZone:TimeZone(identifier:"Asia/Seoul")!)
        #expect(utc.widget.today == nil)
        #expect(utc.widget.yesterday == 100)
        #expect(seoul.widget.today == 100)
    }
    @Test func forkedCumulativeHistoryIsExcludedAndLabelledPartial() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let m: [String:Any] = ["type":"session_meta","timestamp":stamp(-100),"payload":["id":"fork","forked_from_id":"parent"]]
        _ = try write([m,counter(9000)],".codex/sessions/rollout-fork.jsonl",home:h)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == nil); #expect(s.widget.providers.first?.state == .partial)
    }
    @Test func aggregateSerializationContainsNoPromptPathsOrSessionIDs() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write([claude()],".claude/projects/project/a.jsonl",home:h)
        let widget = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt).widget
        let json = String(decoding:try JSONEncoder().encode(widget),as:UTF8.self)
        #expect(!json.contains("SECRET")); #expect(!json.contains("/private")); #expect(!json.contains("claude-1")); #expect(!json.contains("message-1"))
        try WidgetSnapshotStore.write(widget,to:h)
        #expect(WidgetSnapshotStore.read(from:h) == widget)
    }
    @Test func symlinkDoesNotEscapeApprovedLogRoot() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        let external = try write(meta("secret") + [counter(100)],"external.jsonl",home:h)
        let dir = h.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("rollout-link.jsonl"),withDestinationURL:external)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == nil); #expect(s.widget.providers.first?.state == .unavailable)
    }
    @Test func malformedAndNegativeCountersAreNotZero() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at:h) }
        _ = try write(meta("a") + [counter(-5)],".codex/sessions/rollout-a.jsonl",home:h)
        let s = ConcurrentUsageReader().snapshot(home:h,now:now,timeZone:.gmt)
        #expect(s.widget.today == nil); #expect(s.widget.providers.first?.state == .partial)
    }
    @Test func productionRejectsSampleWithoutOverwritingLastRealAggregate() throws {
        let container = try home(); defer { try? FileManager.default.removeItem(at: container) }
        var real = UsagePreviewData.snapshot().widget; real.isSample = false
        try WidgetSnapshotStore.write(real, to: container)
        let original = try Data(contentsOf: container.appendingPathComponent(WidgetSnapshotStore.fileName))
        #expect(throws: CocoaError.self) { try WidgetSnapshotStore.write(UsagePreviewData.snapshot().widget, to: container) }
        #expect(try Data(contentsOf: container.appendingPathComponent(WidgetSnapshotStore.fileName)) == original)
        #expect(WidgetSnapshotStore.read(from: container) == real)
        let sample = UsagePreviewData.snapshot().widget
        try WidgetSnapshotStore.write(sample, to: container, channel: .review)
        #expect(WidgetSnapshotStore.read(from: container) == nil)
        #expect(WidgetSnapshotStore.read(from: container, channel: .review) == sample)
    }
    @Test func legacyBudgetIsIgnoredWithoutChangingUsage() throws {
        let original = UsagePreviewData.snapshot().widget
        let encoded = try JSONEncoder().encode(original)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy["dailyBudget"] = 1
        let restored = try JSONDecoder().decode(WidgetUsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored == original)
        let rewritten = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        #expect(rewritten["dailyBudget"] == nil)
        #expect(restored.today == original.today)
        #expect(restored.providers == original.providers)
    }
    @Test func widgetStaleLargeValuesAndDeepLinkValidation() {
        let s = UsagePreviewData.snapshot().widget
        #expect(s.stale(at:s.generatedAt.addingTimeInterval(1801)))
        #expect(UsageNumbers.add(.max, 100) == .max)
        #expect(UsageNumbers.compact(.max) == "9.2e18")
        #expect(WidgetSnapshotStore.accepts(URL(string:"contextos-review://usage")!,scheme:"contextos-review"))
        #expect(!WidgetSnapshotStore.accepts(URL(string:"contextos-review://usage?path=/private")!,scheme:"contextos-review"))
    }
}
