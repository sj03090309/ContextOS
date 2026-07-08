import Foundation
import Testing
@testable import ContextOSCore

@Suite("ContextService")
struct ContextServiceTests {

    /// Writes a tiny auth-flow project into a fresh temp directory.
    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)

        func write(_ rel: String, _ body: String) throws {
            try body.write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try write("src/login.py", "from auth import authenticate\n\ndef login(u, p):\n    return authenticate(u, p)\n")
        try write("src/auth.py", "from jwt import encode\n\ndef authenticate(u, p):\n    return encode(u)\n")
        try write("src/jwt.py", "def encode(u):\n    return 'token'\n")
        try write("src/billing.py", "def charge(card):\n    return True\n")
        return root
    }

    @Test("auto-indexes on first query")
    func autoIndexes() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ContextService()
        let didBuild = try service.ensureIndexed(projectRoot: root)
        #expect(didBuild)
        // Second call should NOT rebuild.
        #expect(try service.ensureIndexed(projectRoot: root) == false)
    }

    @Test("selects login and its graph neighbours, not billing")
    func selectsRelevant() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let selection = try ContextService().relevantContext(
            query: "fix login", projectRoot: root, tokenBudget: 8000
        )
        let paths = Set(selection.included.map(\.path))
        #expect(paths.contains("src/login.py"))
        #expect(paths.contains("src/auth.py"))
        #expect(!paths.contains("src/billing.py"))
        #expect(selection.contextScore > 0)
    }

    @Test("optimized bundle contains the selected file contents")
    func bundlesContents() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let (selection, bundle) = try ContextService().optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000
        )
        #expect(!selection.included.isEmpty)
        #expect(bundle.contains("def login"))
        #expect(bundle.contains("FILE: src/login.py"))
        #expect(!bundle.contains("def charge")) // billing excluded
    }
}
