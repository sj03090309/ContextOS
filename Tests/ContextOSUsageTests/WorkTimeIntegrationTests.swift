import Foundation
import Testing
import ContextOSUsage
import ContextOSCore

struct WorkTimeIntegrationTests {
    @Test func oldSnapshotRemainsReadableAndTimeHasNoIdentifiers() throws {
        let old = WidgetUsageSnapshot()
        let data = try JSONEncoder().encode(old)
        let legacy = try JSONDecoder().decode(WidgetUsageSnapshot.self, from: data)
        #expect(legacy.timing == nil && legacy.smallMetric == nil)
        let time = WidgetTimeSnapshot(manualNanoseconds: 1_500_000_000, manualState: .paused)
        let dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(time)) as! [String: Any]
        #expect(Set(dict.keys).isSubset(of: ["generatedAt","timeZoneID","manualNanoseconds","foregroundNanoseconds","manualState","foregroundState","isSample"]))
        #expect(WidgetTimeSnapshot.duration(nil) == "—")
        #expect(WidgetTimeSnapshot.duration(0) == "00:00:00")
        #expect(WidgetTimeSnapshot.duration(time.manualNanoseconds) == "00:00:01")
    }
    @Test func unchangedMemoStillAgesAndAppendInvalidatesIt() throws {
        let f=ConcurrentUsageTests();let h=try f.home();defer{try? FileManager.default.removeItem(at:h)}
        let p=try f.write(f.meta("a")+[f.counter(100),f.phase("task_started")],".codex/sessions/rollout-a.jsonl",home:h)
        let reader=ConcurrentUsageReader()
        #expect(reader.snapshot(home:h,now:f.now,timeZone:.gmt).widget.today == 100)
        #expect(reader.snapshot(home:h,now:f.now.addingTimeInterval(4000),timeZone:.gmt).sessions.first?.state == .unknown)
        let bytes=try JSONSerialization.data(withJSONObject:f.counter(120));let handle=try FileHandle(forWritingTo:p)
        try handle.seekToEnd();try handle.write(contentsOf:bytes+Data([10]));try handle.close()
        #expect(reader.snapshot(home:h,now:f.now,timeZone:.gmt).widget.today == 120)
    }
    @Test func oversizedLineAndReadBudgetContinueWithoutCopyingOrInventingZero() throws {
        let f=ConcurrentUsageTests();let h=try f.home();defer{try? FileManager.default.removeItem(at:h)}
        let p=try f.write(f.meta("a"),".codex/sessions/rollout-a.jsonl",home:h)
        let handle=try FileHandle(forWritingTo:p);try handle.seekToEnd();try handle.write(contentsOf:Data(repeating:120,count:3000));try handle.close()
        let reader=ConcurrentUsageReader(maximumLineBytes:512,maximumReadBytes:1024)
        for _ in 0..<4 { let s=reader.snapshot(home:h,now:f.now,timeZone:.gmt);#expect(s.widget.today == nil) }
        let more=try FileHandle(forWritingTo:p);try more.seekToEnd()
        try more.write(contentsOf:Data([10])+JSONSerialization.data(withJSONObject:f.counter(50))+Data([10]));try more.close()
        let s=reader.snapshot(home:h,now:f.now,timeZone:.gmt)
        #expect(s.widget.today == 50)
        #expect(s.widget.providers.first?.state == .partial)
    }
    @Test func metricCapIsPartialAndNewerFilesWinBoundedInventory() throws {
        let f=ConcurrentUsageTests();let h=try f.home();defer{try? FileManager.default.removeItem(at:h)}
        let old=try f.write(f.meta("old")+[f.counter(10)],".codex/sessions/rollout-old.jsonl",home:h)
        let new=try f.write(f.meta("new")+[f.counter(20,-4),f.counter(30,-3),f.counter(40,-2)],".codex/sessions/rollout-new.jsonl",home:h)
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1)],ofItemAtPath:old.path)
        try FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:new.path)
        let s=ConcurrentUsageReader(maximumFilesPerProvider:1,maximumMetrics:2).snapshot(home:h,now:f.now,timeZone:.gmt)
        #expect(s.widget.today == 30)
        #expect(s.widget.providers.first?.state == .partial)
        #expect(s.sessions.count == 1)
    }
}
