import Foundation
import Darwin
import ContextOSCore
import ContextOSUsage

// Short, deterministic synthetic collector benchmark. Never reads real HOME.
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("contextos-usage-bench-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
@MainActor func line(_ value: [String: Any]) throws -> Data {
    var d = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); d.append(10); return d
}
@MainActor func codex(_ id: String, count: Int) throws -> Data {
    var data = try line(["type":"session_meta","timestamp":iso.string(from:now.addingTimeInterval(-60)),"payload":["id":id,"cwd":"/synthetic/contextos"]])
    data.append(try line(["type":"turn_context","timestamp":iso.string(from:now.addingTimeInterval(-50)),"payload":["model":"synthetic-model"]]))
    for n in 1...count { data.append(try counter(n, at: -40 + Double(n) * 0.001)) }
    return data
}
@MainActor func counter(_ n: Int, at offset: Double = -1) throws -> Data {
    try line(["type":"event_msg","timestamp":iso.string(from:now.addingTimeInterval(offset)),"payload":["type":"token_count","info":["total_token_usage":["total_tokens":n,"input_tokens":n,"output_tokens":0,"cached_input_tokens":n]]]])
}
@MainActor func file(_ path: String, data: Data) throws -> URL {
    let url=root.appendingPathComponent(path); try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:url); return url
}
@MainActor func bytes() -> Int64 {
    guard let e=fm.enumerator(at:root,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]) else { return 0 }
    return e.compactMap { $0 as? URL }.reduce(0) { sum,url in
        let v=try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]); return sum + (v?.isRegularFile == true ? Int64(v?.fileSize ?? 0) : 0)
    }
}
@MainActor func rss() -> UInt64? {
    var info=mach_task_basic_info(); var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
    let status=withUnsafeMutablePointer(to:&info) { ptr in ptr.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
        task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
    }}
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
}
@MainActor func cpu() -> Double {
    var r=rusage(); getrusage(RUSAGE_SELF,&r)
    return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)*1000 + Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1000
}
var results:[[String:Any]]=[]
@MainActor func measured(_ name:String,_ body:() throws -> Void) rethrows {
    let tick=DispatchTime.now().uptimeNanoseconds,c=cpu(),disk=bytes(),memory=rss()
    try body()
    var peak=rusage();getrusage(RUSAGE_SELF,&peak)
    var result:[String:Any] = ["scenario":name,"wall_ms":Double(DispatchTime.now().uptimeNanoseconds-tick)/1e6,
        "cpu_ms":cpu()-c,"peak_rss_bytes":peak.ru_maxrss,"fixture_and_aggregate_delta_bytes":bytes()-disk]
    if let memory { result["rss_before_bytes"] = memory }
    if let current = rss() { result["rss_bytes"] = current }
    else { result["rss_unavailable"] = true }
    results.append(result)
}
let reader=ConcurrentUsageReader()
try measured("single_ai_cold") { _ = try file(".codex/sessions/rollout-a.jsonl",data:codex("a",count:25)); _=reader.snapshot(home:root,now:now,timeZone:.gmt) }
measured("idle_200ms") { Thread.sleep(forTimeInterval:0.2) }
measured("single_ai_unchanged_5") { for _ in 0..<5 { _=reader.snapshot(home:root,now:now,timeZone:.gmt) } }
try measured("append_to_aggregate") {
    let path=root.appendingPathComponent(".codex/sessions/rollout-a.jsonl")
    let h=try FileHandle(forWritingTo:path);try h.seekToEnd();try h.write(contentsOf:counter(30));try h.close()
    let s=reader.snapshot(home:root,now:now,timeZone:.gmt);precondition(s.widget.today==30)
}
try measured("concurrent_ai") {
    _=try file(".codex/sessions/rollout-b.jsonl",data:codex("b",count:25))
    let d=try line(["type":"assistant","sessionId":"c","timestamp":iso.string(from:now.addingTimeInterval(-1)),"cwd":"/synthetic/contextos",
        "message":["id":"m","model":"synthetic-model","usage":["input_tokens":10,"output_tokens":5,"cache_read_input_tokens":5,"cache_creation_input_tokens":5]]])
    _=try file(".claude/projects/synthetic/c.jsonl",data:d)
    let s=reader.snapshot(home:root,now:now,timeZone:.gmt);precondition(s.widget.today==80 && s.sessions.count==3)
}
try measured("large_log_cold") {
    var d=try codex("large",count:2000)
    d.append(try line(["type":"response_item","timestamp":iso.string(from:now),"payload":["type":"synthetic-noise","synthetic_padding":String(repeating:"x",count:1024*1024)]]))
    _=try file(".codex/sessions/rollout-large.jsonl",data:d)
    let s=reader.snapshot(home:root,now:now,timeZone:.gmt);precondition(s.widget.today==2080)
}
measured("large_log_unchanged_5") { for _ in 0..<5 { _=reader.snapshot(home:root,now:now,timeZone:.gmt) } }
try measured("rotation_and_replay") {
    let p=root.appendingPathComponent(".codex/sessions/rollout-a.jsonl")
    try fm.moveItem(at:p,to:root.appendingPathComponent(".codex/sessions/rollout-copy.jsonl"))
    var d=try codex("a",count:25);d.append(try counter(30));try d.write(to:p)
    let s=reader.snapshot(home:root,now:now,timeZone:.gmt);precondition(s.widget.today==2080)
    try WidgetSnapshotStore.write(s.widget,to:root)
}
let report:[String:Any]=["configuration":"debug","scope":"synthetic collector only; not full GUI or physical display latency",
    "source_bytes_final":bytes(),"results":results]
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
