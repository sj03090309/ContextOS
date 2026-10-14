import Foundation
import Testing
import Darwin
import ContextOSUsage
import ContextOSCore

struct EstimatedActivityTests {
    let base = ISO8601DateFormatter().date(from:"2026-10-14T12:00:00Z")!
    func input(_ ledger: inout EstimatedActivityLedger, _ sequence: Int64, _ signal: EstimatedActivitySignal, _ second: UInt64, id: String = "a") {
        ledger.receive(id:id,sequence:sequence,signal:signal,tick:second*1_000_000_000,wall:base.addingTimeInterval(Double(second)),timeZone:.gmt)
    }
    func tick(_ ledger: inout EstimatedActivityLedger, _ second: UInt64) {
        ledger.advance(tick:second*1_000_000_000,wall:base.addingTimeInterval(Double(second)),timeZone:.gmt)
    }
    @Test func focusAutomaticallyStartsButIsExplicitlyEstimated() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt)
        #expect(l.snapshot.estimatedNanoseconds == nil)
        input(&l,1,.focus(true),0);#expect(l.snapshot.estimatedNanoseconds == 0)
        tick(&l,10);#expect(l.snapshot.estimatedNanoseconds == 10_000_000_000)
        #expect(l.snapshot.label.contains("추정"))
        input(&l,2,.focus(false),11);tick(&l,30)
        #expect(l.snapshot.estimatedNanoseconds == 11_000_000_000 && l.snapshot.phase == .paused)
    }
    @Test func fiveMinuteIdlePausesAndReadingSignalsResumeWithoutPrompt() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0)
        for s in stride(from:UInt64(30),through:330,by:30) { input(&l,Int64(s/30+1),.heartbeat,s) }
        #expect(l.snapshot.estimatedNanoseconds == 300_000_000_000 && l.snapshot.phase == .paused)
        input(&l,13,.activity(focused:true),350);tick(&l,351)
        #expect(l.snapshot.estimatedNanoseconds == 301_000_000_000 && l.snapshot.phase == .active)
    }
    @Test func heartbeatIsNotActivityAndBackgroundEditsDoNotStartTime() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt)
        input(&l,1,.heartbeat,0);input(&l,2,.activity(focused:false),10);tick(&l,20)
        #expect(l.snapshot.estimatedNanoseconds == nil)
        input(&l,3,.activity(focused:true),30);tick(&l,31)
        #expect(l.snapshot.estimatedNanoseconds == 1_000_000_000)
    }
    @Test func multipleWindowsAndReplaysNeverDoubleCount() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0)
        input(&l,1,.focus(true),10,id:"b");input(&l,2,.focus(false),12)
        tick(&l,20);#expect(l.snapshot.estimatedNanoseconds == 20_000_000_000)
        input(&l,1,.focus(true),25,id:"b");tick(&l,30)
        #expect(l.snapshot.estimatedNanoseconds == 30_000_000_000)
        l.disconnect(id:"a",tick:31_000_000_000,wall:base.addingTimeInterval(31),timeZone:.gmt)
        tick(&l,32);#expect(l.snapshot.estimatedNanoseconds == 32_000_000_000)
    }
    @Test func brokenConnectionLeaseAndSequenceGapsArePartial() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0);tick(&l,1000)
        #expect(l.snapshot.estimatedNanoseconds == 45_000_000_000 && l.snapshot.partial && l.snapshot.phase == .paused)
        #expect(l.snapshot.label.contains("일시정지") && l.snapshot.label.contains("누락"))
        input(&l,2,.heartbeat,1001);tick(&l,1002)
        #expect(l.snapshot.estimatedNanoseconds == 45_000_000_000)
        input(&l,4,.activity(focused:true),1010);tick(&l,1011)
        #expect(l.snapshot.estimatedNanoseconds == 46_000_000_000 && l.snapshot.partial)
    }
    @Test func sleepAndClockChangesDiscardUncheckpointedGaps() {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0);tick(&l,5)
        l.interrupt(tick:100_000_000_000,wall:base.addingTimeInterval(100),timeZone:.gmt)
        input(&l,2,.heartbeat,101);#expect(l.snapshot.estimatedNanoseconds == 5_000_000_000)
        input(&l,3,.activity(focused:true),102);tick(&l,103)
        #expect(l.snapshot.estimatedNanoseconds == 6_000_000_000)
        l.advance(tick:104_000_000_000,wall:base.addingTimeInterval(3600),timeZone:.gmt)
        #expect(l.snapshot.estimatedNanoseconds == 6_000_000_000 && l.snapshot.phase == .paused && l.snapshot.partial)
    }
    @Test func midnightAndTimezoneResetRequireFreshEvent() {
        let near=ISO8601DateFormatter().date(from:"2026-10-14T23:59:59Z")!
        var l=EstimatedActivityLedger(now:near,timeZone:.gmt)
        l.receive(id:"a",sequence:1,signal:.focus(true),tick:0,wall:near,timeZone:.gmt)
        l.advance(tick:2_000_000_000,wall:near.addingTimeInterval(2),timeZone:.gmt)
        #expect(l.snapshot.day == "2026-10-15" && l.snapshot.estimatedNanoseconds == nil && l.snapshot.partial)
        l.receive(id:"a",sequence:2,signal:.heartbeat,tick:3_000_000_000,wall:near.addingTimeInterval(3),timeZone:.gmt)
        #expect(l.snapshot.estimatedNanoseconds == nil)
        l.receive(id:"a",sequence:3,signal:.activity(focused:true),tick:4_000_000_000,wall:near.addingTimeInterval(4),timeZone:.gmt)
        l.advance(tick:5_000_000_000,wall:near.addingTimeInterval(5),timeZone:.gmt)
        #expect(l.snapshot.estimatedNanoseconds == 1_000_000_000)
        l.advance(tick:6_000_000_000,wall:near.addingTimeInterval(6),timeZone:TimeZone(identifier:"Asia/Seoul")!)
        #expect(l.snapshot.estimatedNanoseconds == nil && l.snapshot.timeZoneID == "Asia/Seoul")
    }
    @Test func restartRestoresOnlyStoredAggregateNeverActiveInterval() {
        var old=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&old,1,.focus(true),0);tick(&old,10)
        var fresh=EstimatedActivityLedger(now:base.addingTimeInterval(3600),timeZone:.gmt)
        fresh.restore(old.snapshot,now:base.addingTimeInterval(3600),timeZone:.gmt)
        fresh.advance(tick:0,wall:base.addingTimeInterval(3600),timeZone:.gmt)
        fresh.advance(tick:30_000_000_000,wall:base.addingTimeInterval(3630),timeZone:.gmt)
        #expect(fresh.snapshot.estimatedNanoseconds == 10_000_000_000 && fresh.snapshot.phase == .paused && fresh.snapshot.partial)
    }
    @Test func aggregateStoreHasNoIdentifiersAndRejectsUnsafeFiles() throws {
        let dir=URL(fileURLWithPath:"/tmp/contextos-activity-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:dir)}
        let path=dir.appendingPathComponent("activity-day-v1.json")
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0);tick(&l,10)
        try EstimatedActivityStore.write(l.snapshot,to:path)
        #expect(try EstimatedActivityStore.read(from:path) == l.snapshot)
        let bytes=try Data(contentsOf:path),json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        #expect(Set(json.keys) == ["version","day","timeZoneID","estimatedNanoseconds","phase","partial","idleSeconds","generatedAt"])
        var st=stat();#expect(lstat(path.path,&st)==0 && st.st_mode & 0o077 == 0)
        try Data(repeating:32,count:16385).write(to:path)
        #expect(throws:(any Error).self){try EstimatedActivityStore.read(from:path)}
    }
    @Test func widgetAndWireReceiveSameFrozenAggregate() throws {
        var l=EstimatedActivityLedger(now:base,timeZone:.gmt);input(&l,1,.focus(true),0);tick(&l,10)
        let timing=WidgetTimeSnapshot(activity:l.snapshot)
        var widget=WidgetUsageSnapshot();widget.smallMetric = .activity;widget.timing=timing
        let encoded=try JSONEncoder().encode(widget),decoded=try JSONDecoder().decode(WidgetUsageSnapshot.self,from:encoded)
        #expect(decoded.timing?.activity == l.snapshot && decoded.timing?.activity?.formatted == "00:00:10")
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .millisecondsSince1970
        #expect(try decoder.decode(EstimatedActivitySnapshot.self,from:encoder.encode(l.snapshot)) == l.snapshot)
    }
    @Test func protocolV2CarriesOnlyActivityKindFocusAndCounts() throws {
        let p:[String:Any] = ["version":2,"editor":"vscode","nonce":UUID().uuidString,"sequence":1,"kind":"activity","activity":"scroll","focused":true]
        #expect(try ObservationPacket.decode(JSONSerialization.data(withJSONObject:p)).activity == "scroll")
        var secret=p;secret["range"]=[1,2]
        #expect(throws:(any Error).self){try ObservationPacket.decode(JSONSerialization.data(withJSONObject:secret))}
        var unsupported=p;unsupported["activity"]="keys"
        #expect(throws:(any Error).self){try ObservationPacket.decode(JSONSerialization.data(withJSONObject:unsupported))}
    }
    @Test func daylightSavingClockRepeatUsesMonotonicElapsedTime() {
        let before = ISO8601DateFormatter().date(from: "2026-11-01T05:59:50Z")!, zone = TimeZone(identifier: "America/New_York")!
        var l = EstimatedActivityLedger(now: before, timeZone: zone)
        l.receive(id: "a", sequence: 1, signal: .focus(true), tick: 0, wall: before, timeZone: zone)
        for n in 1...4 { l.receive(id: "a", sequence: Int64(n+1), signal: .heartbeat, tick: UInt64(n)*30_000_000_000, wall: before.addingTimeInterval(Double(n*30)), timeZone: zone) }
        #expect(l.snapshot.day == "2026-11-01" && l.snapshot.estimatedNanoseconds == 120_000_000_000)
    }

}
