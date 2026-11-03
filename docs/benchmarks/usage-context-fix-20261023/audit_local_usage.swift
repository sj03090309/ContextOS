// Run only against a disposable HOME containing a private, fixed input copy.
// Detailed output stays local; do not publish actual-account reports.
import Foundation
import Darwin
import ContextOSCore
import ContextOSUsage
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("expected.json"))) as! [String: Any]
let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let now = iso.date(from: expected["now"] as! String)!
let zone = TimeZone(identifier: "Asia/Seoul")!
let reader = ConcurrentUsageReader()
let start = DispatchTime.now().uptimeNanoseconds
var value = reader.snapshot(home: root, now: now, timeZone: zone)
let cold = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
var passes = 1
while value.widget.providers.contains(where: { $0.isCollecting == true }) && passes < 256 {
    value = reader.snapshot(home: root, now: now, timeZone: zone); passes += 1
}
let completed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
var warm: [Double] = []
for _ in 0..<10 {
    let tick = DispatchTime.now().uptimeNanoseconds
    _ = reader.snapshot(home: root, now: now, timeZone: zone)
    warm.append(Double(DispatchTime.now().uptimeNanoseconds - tick) / 1e6)
}
let todayExpected = (expected["today_tokens"] as! NSNumber).int64Value
precondition(value.widget.today == todayExpected, "Observed collector differs from independent request accounting")
precondition(value.widget.providers.filter { $0.state != .unsupported }.allSatisfy { $0.state == .ready || $0.state == .noRecords }, "Collection did not complete cleanly")
precondition(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL == root.standardizedFileURL, "Calendar audit must use disposable HOME")
let calendarStart = DispatchTime.now().uptimeNanoseconds
let calendar = AgentSessionReader.snapshot(force: true)
let calendarMS = Double(DispatchTime.now().uptimeNanoseconds - calendarStart) / 1e6
let day = expected["today_key"] as! String
precondition(calendar.byDay[day].map(Int64.init) == todayExpected, "Calendar and dashboard accounting differ")
var stats = rusage(); getrusage(RUSAGE_SELF, &stats)
let report: [String: Any] = ["scope": "Frozen recent local transcripts; independent per-request accounting, no model calls", "today_tokens": todayExpected,
    "observed_tokens": value.widget.today!, "calendar_tokens": calendar.byDay[day]!, "agrees_with_independent_accounting": true,
    "source_counts": expected["source_counts"]!, "source_bytes": expected["source_bytes"]!, "request_count": expected["unique_codex_requests"]!,
    "providers": value.widget.providers.map { ["name": $0.name, "state": $0.state.rawValue, "issues": ($0.issues ?? []).map(\.rawValue)] as [String: Any] },
    "bounded_read_passes": passes, "first_pass_ms": cold, "complete_ms": completed, "warm_median_ms": warm.sorted()[5], "calendar_cold_ms": calendarMS, "peak_rss_bytes": stats.ru_maxrss]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
try data.write(to: output)
print("Local accounting validation completed; detailed report saved to the requested output file.")
