import Foundation
import Darwin
import Testing
@testable import ContextOSCore

@Suite("GitAnalyzer")
struct GitAnalyzerTests {

    /// Create a temp git repo with one committed file and one uncommitted change.
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)

        func git(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git"] + args
            p.currentDirectoryURL = root
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
        }
        func write(_ rel: String, _ body: String) throws {
            try body.write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }

        try git(["init", "-q"])
        try git(["config", "user.email", "t@t.dev"])
        try git(["config", "user.name", "Test"])
        try write("src/login.py", "def login():\n    pass\n")
        try write("src/billing.py", "def charge():\n    pass\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "init"])
        // Now make billing.py an uncommitted change.
        try write("src/billing.py", "def charge():\n    return True\n")
        return root
    }

    @Test("detects repo, branch, commits, and changed files")
    func readsState() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let git = GitAnalyzer()
        #expect(git.isRepository(root))
        #expect(git.currentBranch(root) != nil)
        #expect(!git.recentCommits(root).isEmpty)
        #expect(git.changedFiles(root).contains("src/billing.py"))
    }

    @Test("returns empty signals outside a repository")
    func emptyOutsideRepo() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(GitAnalyzer().signals(tmp).isEmpty)
    }

    @Test("metadata reads never execute a repository fsmonitor hook or refresh its index")
    func metadataDoesNotRunRepositoryCommandsOrWriteIndex() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("FS_MONITOR_EXECUTED")
        let hook = root.appendingPathComponent("monitor.sh")
        try "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        #expect(GitRunner.run(["config", "core.fsmonitor", hook.path], in: root) != nil)

        let index = root.appendingPathComponent(".git/index")
        let before = try Data(contentsOf: index)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        let git = GitAnalyzer()
        #expect(git.changedFiles(root).contains("src/billing.py"))
        #expect(!git.recentCommits(root).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try Data(contentsOf: index) == before)
        let after = try FileManager.default.attributesOfItem(atPath: index.path)
        #expect(after[.modificationDate] as? Date == attributes[.modificationDate] as? Date)
        #expect(GitRunner.run(["config", "--get", "core.fsmonitor"], in: root)?.trimmingCharacters(in: .whitespacesAndNewlines) == "false")
        // Command overrides apply to the child only; the user's config remains.
        let config = try String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(config.contains(hook.path))
    }

    @Test("a blocked repository config read times out and reaps its child")
    func blockedGitMetadataTimesOut() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("blocked-config")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let config = root.appendingPathComponent(".git/config")
        var text = try String(contentsOf: config, encoding: .utf8)
        text += "\n[include]\n\tpath = \(fifo.path)\n"
        try text.write(to: config, atomically: true, encoding: .utf8)
        let started = Date()
        #expect(GitRunner.run(["rev-parse", "--is-inside-work-tree"], in: root, timeout: 0.2) == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("uncommitted file gets boosted into context even without a lexical match")
    func gitBoostSurfacesEditedFile() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Query "billing" would match billing.py lexically, so query something
        // unrelated: the git-changed file should still surface via the boost.
        let selection = try ContextService().relevantContext(
            query: "login", projectRoot: root, tokenBudget: 8000
        )
        let paths = Set(selection.included.map(\.path))
        #expect(paths.contains("src/login.py"))     // lexical match
        #expect(paths.contains("src/billing.py"))   // git-changed boost
        let billing = selection.included.first { $0.path == "src/billing.py" }
        #expect(billing?.reasons.contains { $0.contains("git") } == true)
    }
}
