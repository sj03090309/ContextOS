import Foundation
import CryptoKit
import Darwin
import ContextOSCore

// Deterministic synthetic input only. Pass a disposable directory, never a user project.
let arguments = CommandLine.arguments
guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "--dashboard"), let count = Int(arguments[2]), (10...5000).contains(count) else {
    fputs("Usage: contextos-bench <empty temporary directory> <file count 10...5000> [--dashboard]\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: arguments[1], isDirectory: true).standardizedFileURL
let fm = FileManager.default
let preparedDashboardHome = arguments.count == 4
    && (try? fm.contentsOfDirectory(atPath: root.path)) == ["home"]
    && (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("home").path)) == []
guard !fm.fileExists(atPath: root.path) || preparedDashboardHome else {
    fputs("Benchmark directory must not exist.\n", stderr); exit(2)
}
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let sourceDir = root.appendingPathComponent("Sources")
try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
var sourceBytes = 0
for index in 0..<count {
    var source = "import Foundation\n"
    for symbol in 0..<24 {
        source += "func loginSessionTokenCacheValidationService\(index)Step\(symbol)(_ value: String) -> String {\n"
        source += "    let normalized = value.lowercased()\n    return normalized + \"fixture-\(index)-\(symbol)\"\n}\n"
    }
    sourceBytes += source.utf8.count
    try source.write(to: sourceDir.appendingPathComponent("Service\(index).swift"), atomically: true, encoding: .utf8)
}
try "Sources/ignored.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
try "DUMMY_PRIVATE_VALUE".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
func measure(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try autoreleasepool { try body() }
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}
let indexer = Indexer()
var coldStats = IndexStats()
let cold = try measure { coldStats = try indexer.index(projectRoot: root) }
let scanTimes = try (0..<9).map { _ in try measure { _ = try ProjectScanner().scan(root: root) } }
let warmTimes = try (0..<9).map { _ in try measure { _ = try indexer.index(projectRoot: root) } }
let store = try Indexer.openStore(forProjectRoot: root)
let optimizer = ContextOptimizer()
let terms = ["login", "session", "token", "cache", "validation", "service"]
var selection: ContextSelection?
let rankTimes = try (0..<7).map { _ in try measure {
    selection = try optimizer.selectContext(query: terms.joined(separator: " "), from: store, tokenBudget: 8000, overrideTerms: terms)
} }
let service = ContextService(useGitSignals: false)
var bundle = ""
let queryTimes = try (0..<5).map { _ in try measure {
    bundle = try service.optimizedBundle(query: "login session token cache validation service", projectRoot: root, tokenBudget: 8000).bundle
} }
let scored = (selection!.included + selection!.excluded).map { "\($0.path):\($0.score):\($0.estimatedTokens)" }.joined(separator: "\n")
let digest = SHA256.hash(data: Data((scored + "\n" + bundle).utf8)).map { String(format: "%02x", $0) }.joined()
guard try store.fileCount() == count, try store.symbolCount() == count * 24,
      !bundle.contains("DUMMY_PRIVATE_VALUE"), TokenEstimator().estimate(text: bundle) <= 8000 else {
    fputs("Synthetic benchmark correctness check failed.\n", stderr); exit(1)
}
var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
var report: [String: Any] = [
    "fixture": ["files": count, "symbols": try store.symbolCount(), "source_bytes": sourceBytes, "terms": terms],
    "configuration": "release", "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "architecture": "\(MemoryLayout<Int>.size * 8)-bit", "processor_count": ProcessInfo.processInfo.processorCount,
    "measurements_ms": ["cold_index": cold, "scan_median_9": median(scanTimes), "warm_index_median_9": median(warmTimes),
                        "rank_median_7": median(rankTimes), "query_median_5": median(queryTimes)],
    "peak_rss_bytes": usage.ru_maxrss, "correctness_digest": digest,
    "indexed_files": try store.fileCount(), "selected_files": selection!.included.count,
    "bundle_estimated_tokens": TokenEstimator().estimate(text: bundle)
]
let watcherRoot = "/synthetic/project"
let eventPaths = (0..<10_000).map { index in
    switch index % 10 {
    case 0: return watcherRoot + "/.contextos"
    case 1: return watcherRoot + "/.build"
    case 2: return watcherRoot + "/private.pem"
    case 3: return watcherRoot + "/.contextos/index.sqlite-wal"
    case 4: return watcherRoot + "/.build/generated.swift"
    case 5: return watcherRoot + "/node_modules/pkg/index.js"
    default: return watcherRoot + "/Sources/Service\(index).swift"
    }
}
let oldFragments = ["/.contextos/", "/.git/", "/node_modules/", "/.build/", "/DerivedData/", "/dist/", "/.next/", "/__pycache__/"]
let oldAccepted = eventPaths.filter { path in !oldFragments.contains { path.contains($0) } }.count
let oldWatcherTimes = (0..<3).map { _ in measure {
    _ = eventPaths.filter { path in !oldFragments.contains { path.contains($0) } }.count
} }
var accepted = 0
let watcherTimes = (0..<3).map { _ in measure {
    accepted = eventPaths.filter { FileWatcher.shouldReindex(path: $0, roots: [watcherRoot], isDirectory: $0.hasSuffix("/.build") || $0.hasSuffix("/.contextos")) }.count
} }
guard accepted == 4000 else { fputs("Watcher fixture classification failed.\n", stderr); exit(1) }
report["watcher"] = ["events": eventPaths.count, "old_accepted": oldAccepted, "new_accepted": accepted,
                     "old_classifier_median_ms_3": median(oldWatcherTimes), "classifier_median_ms_3": median(watcherTimes)]
if arguments.count == 4 {
    let expectedHome = root.appendingPathComponent("home").standardizedFileURL
    guard FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL == expectedHome else {
        fputs("Dashboard benchmark needs CFFIXED_USER_HOME=<fixture directory>/home. Real session logs will not be read.\n", stderr); exit(2)
    }
    let logs = expectedHome.appendingPathComponent(".claude/projects/synthetic")
    try fm.createDirectory(at: logs, withIntermediateDirectories: true)
    let line = "{\"type\":\"assistant\",\"timestamp\":\"2026-07-01T10:00:00.000Z\",\"cwd\":\"/synthetic/project\",\"message\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":10}}}\n"
    let transcript = String(repeating: line, count: 2000)
    for index in 0..<4 { try transcript.write(to: logs.appendingPathComponent("fixture\(index).jsonl"), atomically: true, encoding: .utf8) }
    var snapshot = AgentUsageSnapshot()
    let cold = measure { snapshot = AgentSessionReader.snapshot(force: true) }
    let warm = (0..<9).map { _ in measure { snapshot = AgentSessionReader.snapshot(force: true) } }
    let cached = (0..<9).map { _ in measure { snapshot = AgentSessionReader.snapshot() } }
    guard snapshot.totalTokens == 880_000 else { fputs("Synthetic log aggregation failed.\n", stderr); exit(1) }
    report["dashboard_data"] = ["transcripts": 4, "transcript_bytes": transcript.utf8.count * 4,
                              "total_tokens": snapshot.totalTokens, "cold_ms": cold, "warm_median_ms_9": median(warm),
                              "memoized_median_ms_9": median(cached), "ui_rendering_measured": false]
}
let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
print(String(decoding: output, as: UTF8.self))
