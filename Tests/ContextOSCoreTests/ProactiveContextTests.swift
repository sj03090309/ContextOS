import Foundation
import Testing
@testable import ContextOSCore

@Suite("Proactive context")
struct ProactiveContextTests {

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-proactive-\(UUID().uuidString)")
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
        try git(["config", "user.name", "T"])
        try write("src/login.py", "def login():\n    return 1\n")
        try write("src/billing.py", "def charge():\n    return 2\n")
        try git(["add", "."]); try git(["commit", "-q", "-m", "init"])
        // Uncommitted edit:
        try write("src/billing.py", "def charge():\n    return 999\n")
        return root
    }

    @Test("builds context from uncommitted files with no query")
    func proactiveFromChanges() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try ContextService().proactiveContext(projectRoot: root)
        #expect(result != nil)
        let paths = Set(result?.selection.included.map(\.path) ?? [])
        #expect(paths.contains("src/billing.py"))       // the file being edited
        #expect(result?.bundle.contains("def charge") == true)
    }

    @Test("returns nil when the working tree is clean")
    func nilWhenClean() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        // Commit the change so the tree is clean.
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "commit", "-aqm", "x"]; p.currentDirectoryURL = root
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()

        #expect(try ContextService().proactiveContext(projectRoot: root) == nil)
    }
}
