import Foundation
import Testing
import Darwin
@testable import ContextOSCore

@Suite("Runtime privacy and transcript identity")
struct RuntimePrivacyTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-runtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func applicationNeedsExplicitBooleanLogConsent() throws {
        let name = "contextos-consent-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: "com.contextos.app"))
        defaults.set(1, forKey: AgentLogCollectionPolicy.preferenceKey)
        #expect(!AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: "com.contextos.app"))
        defaults.removeObject(forKey: AgentLogCollectionPolicy.preferenceKey)
        defaults.set(true, forKey: AgentLogCollectionPolicy.preferenceKey)
        #expect(AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: "com.contextos.app"))
        defaults.set(false, forKey: AgentLogCollectionPolicy.preferenceKey)
        #expect(!AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: "com.contextos.app"))
        #expect(AgentLogCollectionPolicy.permits(defaults: defaults, applicationBundleIdentifier: nil))
    }

    @Test func analyticsDatabaseAndSidecarsArePrivateOnCreateAndReopen() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("data/usage.sqlite")
        let first = try UsageStore(path: file.path)
        try first.record(.init(project: "/synthetic/project", query: "synthetic private query", selectedTokens: 1, fullTokens: 2, contextScore: 1, fileCount: 1))
        func mode(_ file: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            return (try #require(attrs[.posixPermissions] as? NSNumber)).intValue & 0o777
        }
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
        for name in ["usage.sqlite", "usage.sqlite-wal", "usage.sqlite-shm"] {
            let part = file.deletingLastPathComponent().appendingPathComponent(name)
            #expect(try mode(part) == 0o600)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: part.path)
        }
        let second = try UsageStore(path: file.path)
        #expect(second.summary().queryCount == 1)
        for name in ["usage.sqlite", "usage.sqlite-wal", "usage.sqlite-shm"] {
            #expect(try mode(file.deletingLastPathComponent().appendingPathComponent(name)) == 0o600)
        }
    }

    @Test func linkedAnalyticsDatabaseIsRejectedWithoutChangingItsTarget() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.sqlite")
        let store = try UsageStore(path: original.path)
        let link = root.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: (any Error).self) { _ = try UsageStore(path: link.path) }
        #expect(store.summary().queryCount == 0)
    }

    @Test func atomicallyReplacedLargerTranscriptDoesNotAppendToOldAccounting() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        func line(_ id: String, _ count: Int, padding: String = "") -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"2026-10-20T10:00:00Z\",\"cwd\":\"/synthetic/project\",\"padding\":\"\(padding)\",\"message\":{\"id\":\"\(id)\",\"usage\":{\"input_tokens\":\(count),\"output_tokens\":0}}}\n"
        }
        try line("old", 100).write(to: file, atomically: true, encoding: .utf8)
        let cached = try #require(AgentSessionReader.row(for: file, agent: "Claude Code", cached: nil))
        #expect(cached.tokens == 100)
        try line("new", 7, padding: String(repeating: "x", count: 500)).write(to: file, atomically: true, encoding: .utf8)
        let changed = try #require(AgentSessionReader.row(for: file, agent: "Claude Code", cached: cached))
        let full = try #require(AgentSessionReader.row(for: file, agent: "Claude Code", cached: nil))
        #expect(changed.tokens == 7)
        #expect(changed.projects == full.projects)
    }

    @Test func transcriptSymlinkDoesNotReuseOrReadAnExternalFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try "{\"cwd\":\"/synthetic\",\"message\":{\"usage\":{\"input_tokens\":50,\"output_tokens\":0}}}\n".write(to: file, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(AgentSessionReader.row(for: link, agent: "Claude Code", cached: nil) == nil)
    }

    @Test func persistedTranscriptIdentityInvalidatesAReplacementAfterRelaunch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-test.jsonl")
        func text(_ count: Int) -> String {
            "{\"type\":\"session_meta\",\"payload\":{\"cwd\":\"/synthetic\"}}\n"
            + "{\"timestamp\":\"2026-10-20T10:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(count)}}}}\n"
        }
        try text(100).write(to: file, atomically: true, encoding: .utf8)
        let first = try #require(AgentSessionReader.row(for: file, agent: "Codex", cached: nil))
        let store = try UsageStore(path: root.appendingPathComponent("usage.sqlite").path)
        try store.upsertSessionCache([first])
        let cached = try #require(store.sessionCache()[file.path])
        #expect(cached.fileIdentity == first.fileIdentity)
        try text(200).write(to: file, atomically: true, encoding: .utf8)
        // Even a matching mtime and byte count cannot establish file identity.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: first.mtime)], ofItemAtPath: file.path)
        let changed = try #require(AgentSessionReader.row(for: file, agent: "Codex", cached: cached))
        #expect(changed.tokens == 200)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        #expect(AgentSessionReader.row(for: file, agent: "Codex", cached: changed) == nil)
    }

    @Test func linkedOrHardLinkedAnalyticsSidecarsFailWithoutTouchingTheirTargets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("preserved")
        let contents = Data("synthetic file that must stay unchanged".utf8)
        try contents.write(to: target)
        for hardLink in [false, true] {
            let database = root.appendingPathComponent(hardLink ? "hard.sqlite" : "symbolic.sqlite")
            let sidecar = URL(fileURLWithPath: database.path + "-wal")
            if hardLink { try FileManager.default.linkItem(at: target, to: sidecar) }
            else { try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target) }
            #expect(throws: (any Error).self) { _ = try UsageStore(path: database.path) }
            #expect(try Data(contentsOf: target) == contents)
            let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o644)
        }
    }

    @Test func activityDiscoveryAndTrackerRejectLinkedRootsAndLogFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let log = outside.appendingPathComponent("rollout-test.jsonl")
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        try "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".codex"), withDestinationURL: outside)
        let monitor = AgentActivityMonitor(home: root)
        monitor.rescan(now: now)
        #expect(monitor.sessionLogs.isEmpty)
        let link = root.appendingPathComponent("rollout-linked.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        let snapshot = SessionActivityTracker().snapshot(logs: [(link, now)], now: now)
        #expect(snapshot.activeSessions == 0)
        #expect(snapshot.selected?.phase != .working)
        #expect(!AgentActivityMonitor.hasPendingToolCall(link))
    }
}
