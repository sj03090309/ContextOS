import Foundation
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
