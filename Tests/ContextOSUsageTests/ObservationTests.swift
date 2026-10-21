import Foundation
import Testing
import Darwin
import ContextOSUsage
import ContextOSCore

struct ObservationTests {
    let now = ISO8601DateFormatter().date(from: "2025-10-12T00:30:00Z")!
    func event(_ id: String, _ kind: ExplicitAIRunEvent.Kind, _ seconds: Double) -> ExplicitAIRunEvent {
        .init(id: id, kind: kind, date: now.addingTimeInterval(seconds))
    }
    @Test func explicitPairsUnionAndReplayWithoutFillingGaps() {
        let e = [event("a",.start,-100),event("a",.end,-60),event("b",.start,-80),event("b",.end,-50),event("c",.start,-20),event("c",.end,-10)]
        let value = ExplicitAIRuns.summarize(e + e, now: now, timeZone: .gmt)
        #expect(value.todayMilliseconds == 60_000)
        #expect(value.state == .ready)
    }
    @Test func missingConflictingAbortedReversedAndFuturePairsAreNotTime() {
        let e = [event("open",.start,-50),event("orphan",.end,-10),
                 event("conflict",.start,-50),event("conflict",.start,-40),event("conflict",.end,-10),
                 event("abort",.start,-40),event("abort",.abort,-20),event("abort",.end,-10),
                 event("reverse",.start,-10),event("reverse",.end,-20),event("future",.start,-1),event("future",.end,1)]
        let value = ExplicitAIRuns.summarize(e, now: now, timeZone: .gmt)
        #expect(value.todayMilliseconds == nil && value.state == .partial && value.missingPairs == 6)
        let zero = ExplicitAIRuns.summarize([event("zero",.start,-1),event("zero",.end,-1)], now: now, timeZone: .gmt)
        #expect(zero.todayMilliseconds == 0 && zero.formatted == "00:00:00")
    }
    @Test func midnightTimezoneAndDSTUseRealDayBoundaries() {
        let e = [event("cross",.start,-1900),event("cross",.end,-1700)]
        #expect(ExplicitAIRuns.summarize(e,now:now,timeZone:.gmt).todayMilliseconds == 100_000)
        #expect(ExplicitAIRuns.summarize(e,now:now,timeZone:TimeZone(secondsFromGMT: -3600)!).todayMilliseconds == 200_000)
        let zone = TimeZone(identifier:"America/New_York")!
        let end=ISO8601DateFormatter().date(from:"2025-11-03T04:59:00Z")!,start=ISO8601DateFormatter().date(from:"2025-11-02T04:00:00Z")!
        let d = ExplicitAIRuns.summarize([.init(id:"dst",kind:.start,date:start),.init(id:"dst",kind:.end,date:end)],now:end,timeZone:zone)
        #expect(d.todayMilliseconds == 89_940_000)
    }
    @Test func readerUsesOnlyCorrelatedCodexLifecycleAndMergesCopies() throws {
        let f=ConcurrentUsageTests(),h=try f.home();defer{try? FileManager.default.removeItem(at:h)}
        func phase(_ kind:String,_ seconds:Double,_ id:String?) -> [String:Any] {
            var p:[String:Any] = ["type":kind]; if let id { p["turn_id"]=id }
            return ["type":"event_msg","timestamp":f.stamp(seconds),"payload":p]
        }
        let lines=f.meta("a")+[phase("task_started",-100,"t"),phase("task_complete",-50,"t"),f.counter(100)]
        _=try f.write(lines,".codex/sessions/rollout-a.jsonl",home:h)
        _=try f.write(lines,".codex/sessions/rollout-copy.jsonl",home:h)
        _=try f.write([f.claude()],".claude/projects/p/a.jsonl",home:h)
        let r=ConcurrentUsageReader(),v=r.snapshot(home:h,now:f.now,timeZone:.gmt)
        #expect(v.aiExecution.todayMilliseconds == 50_000)
        #expect(v.widget.today == 300) // 100 Codex + 200 disjoint Claude accounting.
        #expect(r.snapshot(home:h,now:f.now.addingTimeInterval(100),timeZone:.gmt).aiExecution.todayMilliseconds == 50_000)
        _=try f.write(f.meta("b")+[phase("user_message",-100,nil),f.counter(100)],".codex/sessions/rollout-b.jsonl",home:h)
        #expect(r.snapshot(home:h,now:f.now,timeZone:.gmt).aiExecution.todayMilliseconds == 50_000)
    }
    func packet(_ kind: String = "edits", sequence:Int=1, nonce:String="12345678-1234-1234-1234-123456789abc", extra:[String:Any]=[:]) throws -> Data {
        var p:[String:Any] = ["version":1,"editor":"vscode","nonce":nonce,"sequence":sequence,"kind":kind]
        if kind == "edits" {p["count"]=2}; if kind == "focus" {p["focused"]=true}
        p.merge(extra){_,new in new};return try JSONSerialization.data(withJSONObject:p)
    }
    @Test func bridgeSchemaRejectsSecretsOversizeAndWrongTypes() throws {
        #expect(throws:(any Error).self) { try ObservationPacket.decode(packet(extra:["text":"private"])) }
        #expect(throws:(any Error).self) { try ObservationPacket.decode(packet(extra:["count":true])) }
        #expect(throws:(any Error).self) { try ObservationPacket.decode(packet("focus",extra:["focused":1])) }
        #expect(throws:(any Error).self) { try ObservationPacket.decode(packet(extra:["count":257])) }
        #expect(throws:(any Error).self) { try ObservationPacket.decode(Data(repeating:32,count:1025)) }
        #expect(try ObservationPacket.decode(packet()).count == 2)
    }
    @Test func bridgeReplayGapsRestartAndDisconnectNeverAddTime() throws {
        var ledger=ObservationBridgeLedger()
        ledger.consume(try ObservationPacket.decode(packet()))
        ledger.consume(try ObservationPacket.decode(packet()))
        #expect(ledger.editCount == 2 && !ledger.partial)
        ledger.consume(try ObservationPacket.decode(packet(sequence:3)))
        #expect(ledger.editCount == 4 && ledger.partial)
        ledger.consume(try ObservationPacket.decode(packet("focus",sequence:4)))
        #expect(ledger.focused == true)
        ledger.disconnect(); #expect(ledger.focused == nil)
        ledger.consume(try ObservationPacket.decode(packet(nonce:"87654321-1234-1234-1234-123456789abc")))
        #expect(ledger.editCount == 6 && ledger.partial)
    }
    @Test func receiverLeaseRejectsLateCallbacksAndUnboundPersistence() {
        var lease = ObservationReceiverLease()
        let first = lease.begin(); #expect(!lease.isReady)
        let firstReady = lease.ready(first); #expect(firstReady); #expect(lease.isReady)
        lease.invalidate(); #expect(!lease.isReady && !lease.accepts(first))
        let second = lease.begin()
        let lateReady = lease.ready(first); #expect(!lateReady && !lease.isReady)
        let secondReady = lease.ready(second); #expect(secondReady && lease.isReady)
    }
    @Test func legacyActivityImportIsPausedAndNeverOverwritesOrDeletes() throws {
        let directory=URL(fileURLWithPath:"/tmp").appendingPathComponent("contextos-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let old=directory.appendingPathComponent("legacy.json"),dest=directory.appendingPathComponent("production.json")
        let value=EstimatedActivitySnapshot(now:now,timeZone:.gmt,estimatedNanoseconds:20_000_000_000,phase:.active)
        try EstimatedActivityStore.write(value,to:old);let original=try Data(contentsOf:old)
        #expect(try EstimatedActivityStore.importLegacyIfAbsent(from:old,to:dest,now:now,timeZone:.gmt))
        let restored=try #require(try EstimatedActivityStore.read(from:dest))
        #expect(restored.estimatedNanoseconds==value.estimatedNanoseconds && restored.phase == .paused && restored.partial)
        #expect(try Data(contentsOf:old)==original)
        #expect(try !EstimatedActivityStore.importLegacyIfAbsent(from:old,to:dest,now:now.addingTimeInterval(30),timeZone:.gmt))
        #expect(try EstimatedActivityStore.read(from:dest)==restored)
        let nextDay=directory.appendingPathComponent("next-day.json")
        #expect(try !EstimatedActivityStore.importLegacyIfAbsent(from:old,to:nextDay,now:now.addingTimeInterval(86400),timeZone:.gmt))
        #expect(!FileManager.default.fileExists(atPath:nextDay.path))
    }
    @Test func occupiedReceiverCannotBecomeReadyOrRemoveTheOwnerSocket() async throws {
        actor State {
            var ready = false, failed = false
            func record(_ event: ObservationBridgeEvent) { if case .ready = event { ready = true }; if case .failed = event { failed = true } }
            func values() -> (Bool,Bool) { (ready,failed) }
        }
        let directory=URL(fileURLWithPath:"/tmp").appendingPathComponent("contextos-owner-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let a=State(),b=State()
        let owner=ObservationBridgeServer { e in Task { await a.record(e) } }
        let other=ObservationBridgeServer { e in Task { await b.record(e) } }
        defer { other.stopSynchronously(); owner.stopSynchronously() }
        owner.start(directory:directory)
        for _ in 0..<100 { if await a.values().0 { break }; try await Task.sleep(for:.milliseconds(10)) }
        #expect(await a.values().0)
        let path=directory.appendingPathComponent("observations.sock").path
        var before=stat(); try #require(lstat(path,&before)==0)
        other.start(directory:directory)
        for _ in 0..<100 { if await b.values().1 { break }; try await Task.sleep(for:.milliseconds(10)) }
        let state=await b.values(); #expect(!state.0 && state.1)
        other.stopSynchronously()
        var after=stat(); #expect(lstat(path,&after)==0 && before.st_ino==after.st_ino)
    }
    @Test func unixReceiverAcceptsSyntheticPacketAndPreservesExistingPath() async throws {
        actor Box { var events:[ObservationBridgeEvent]=[]; func add(_ e:ObservationBridgeEvent){events.append(e)}; func count()->Int{events.filter { if case .packet = $0 { return true }; return false }.count} }
        let directory=URL(fileURLWithPath:"/tmp",isDirectory:true).appendingPathComponent("contextos-bridge-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        let box=Box(),server=ObservationBridgeServer { e in Task { await box.add(e) } }
        let path=directory.appendingPathComponent("observations.sock").path
        server.start(directory:directory)
        var st=stat()
        for _ in 0..<100 { if lstat(path,&st)==0 {break};try await Task.sleep(for:.milliseconds(10)) }
        try #require((st.st_mode & S_IFMT) == S_IFSOCK && st.st_mode & 0o077 == 0)
        let fd=socket(AF_UNIX,SOCK_STREAM,0);defer{close(fd)}
        try #require(path.utf8.count < 104)
        var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of:&address.sun_path){ dest in path.utf8CString.withUnsafeBytes{dest.copyBytes(from:$0)} }
        let connected=withUnsafePointer(to:&address){p in p.withMemoryRebound(to:sockaddr.self,capacity:1){ Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(connected == 0)
        var bytes=try packet();bytes.append(10)
        let sent=bytes.withUnsafeBytes{Darwin.write(fd,$0.baseAddress,$0.count)};#expect(sent == bytes.count)
        for _ in 0..<100 {if await box.count()>0{break};try await Task.sleep(for:.milliseconds(10))}
        #expect(await box.count()>0)
        let shared = EstimatedActivitySnapshot(now: now, timeZone: .gmt, estimatedNanoseconds: 10_000_000_000, phase: .active)
        server.publish(shared)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var response = [UInt8](repeating: 0, count: 2048)
        let received = Darwin.read(fd, &response, response.count)
        try #require(received > 0)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        #expect(try decoder.decode(EstimatedActivitySnapshot.self, from: Data(response.prefix(received))) == shared)
        server.stopSynchronously()
        for _ in 0..<100 {if lstat(path,&st) != 0{break};try await Task.sleep(for:.milliseconds(10))}
        let sentinel=Data("preserve".utf8);try sentinel.write(to:URL(fileURLWithPath:path))
        server.start(directory:directory)
        try await Task.sleep(for:.milliseconds(50));server.stop()
        #expect(try Data(contentsOf:URL(fileURLWithPath:path)) == sentinel)
    }

    @Test func receiverRecoversOnlyPrivateOrphanSocketsAndRestarts() async throws {
        actor State {
            var ready = false, failed = false
            func add(_ e: ObservationBridgeEvent) { if case .ready = e { ready = true }; if case .failed = e { failed = true } }
            func value() -> (Bool, Bool) { (ready, failed) }
        }
        let directory=URL(fileURLWithPath:"/tmp").appendingPathComponent("cx-recovery-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:directory) }
        let path=directory.appendingPathComponent("observations.sock").path
        func bindSocket() throws -> Int32 {
            let fd=socket(AF_UNIX,SOCK_STREAM,0)
            var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of:&address.sun_path) { dest in path.utf8CString.withUnsafeBytes { dest.copyBytes(from:$0) } }
            let result=withUnsafePointer(to:&address) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { close(fd); throw BridgeError.socketFailure }
            chmod(path,0o600);return fd
        }
        // Even an older receiver without our lock must remain untouched.
        let live=try bindSocket();try #require(listen(live,4)==0)
        let rejected=State(), contender=ObservationBridgeServer { e in Task { await rejected.add(e) } }
        contender.start(directory:directory)
        for _ in 0..<100 { if await rejected.value().1 { break };try await Task.sleep(for:.milliseconds(10)) }
        #expect(await rejected.value().1);contender.stopSynchronously()
        var old=stat();try #require(lstat(path,&old)==0)
        close(live) // Models an unclean exit: the pathname remains, no listener.
        for _ in 0..<3 {
            let state=State(),server=ObservationBridgeServer { e in Task { await state.add(e) } }
            server.start(directory:directory)
            for _ in 0..<100 { if await state.value().0 { break };try await Task.sleep(for:.milliseconds(10)) }
            #expect(await state.value().0);#expect(await !state.value().1)
            server.stopSynchronously()
            var st=stat();#expect(lstat(path,&st) != 0)
        }
        // A lock symlink is never followed, replaced, or chmod'ed.
        let lock=directory.appendingPathComponent("receiver.lock")
        try FileManager.default.removeItem(at:lock)
        let sentinel=directory.appendingPathComponent("sentinel");try Data("preserve".utf8).write(to:sentinel)
        try FileManager.default.createSymbolicLink(at:lock,withDestinationURL:sentinel)
        let denied=State(),server=ObservationBridgeServer { e in Task { await denied.add(e) } }
        server.start(directory:directory)
        for _ in 0..<100 { if await denied.value().1 { break };try await Task.sleep(for:.milliseconds(10)) }
        server.stopSynchronously();#expect(await denied.value().1)
        #expect(try Data(contentsOf:sentinel)==Data("preserve".utf8))
    }
}
