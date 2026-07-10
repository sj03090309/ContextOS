import XCTest
@testable import ContextOSCore

/// The new token-efficiency levers: session dedup + signature outlines.
final class TokenEfficiencyTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-eff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try """
        def login(user, password):
            return check(user, password)

        def check(user, password):
            return True
        """.write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)
        try """
        import login

        def make_session(user):
            return {"user": user}
        """.write(to: root.appendingPathComponent("src/auth.py"), atomically: true, encoding: .utf8)
        return root
    }

    func testSessionMemorySkipsUnchangedBodies() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()
        let memory = SessionMemory()

        let first = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: memory)
        XCTAssertEqual(first.skippedUnchanged, 0)
        XCTAssertTrue(first.bundle.contains("def login"))

        // Same query again: identical bodies must be skipped, not resent.
        let second = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: memory)
        XCTAssertGreaterThan(second.skippedUnchanged, 0)
        XCTAssertFalse(second.bundle.contains("def login"))
        XCTAssertTrue(second.bundle.contains("이미 전달"))
    }

    func testChangedFileIsResent() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()
        let memory = SessionMemory()

        _ = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: memory)

        // Edit the file — the next bundle must carry the fresh body.
        try """
        def login(user, password):
            return verify_two_factor(user, password)
        """.write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)
        _ = try service.reindex(projectRoot: root)

        let second = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: memory)
        XCTAssertTrue(second.bundle.contains("verify_two_factor"))
    }

    func testWithoutMemoryNothingIsSkipped() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()

        let a = try service.optimizedBundle(query: "fix login", projectRoot: root, tokenBudget: 8000)
        let b = try service.optimizedBundle(query: "fix login", projectRoot: root, tokenBudget: 8000)
        XCTAssertEqual(a.skippedUnchanged, 0)
        XCTAssertEqual(b.skippedUnchanged, 0)
        XCTAssertTrue(b.bundle.contains("def login"))
    }

    func testExcludedFilesGetSignatureOutline() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // A tiny budget forces at least one relevant file out.
        let (selection, bundle, _) = try ContextService().optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 30)
        XCTAssertFalse(selection.excluded.isEmpty)
        XCTAssertTrue(bundle.contains("시그니처 목차"))
        // The outline names the excluded file and lists a symbol with its line.
        let excludedPath = selection.excluded[0].path
        XCTAssertTrue(bundle.contains(excludedPath))
    }
}

/// Multi-agent `connect`: config writers for Codex/Gemini/Cursor/Windsurf.
final class AgentIntegrationTests: XCTestCase {

    private func makeHome(dirs: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-home-\(UUID().uuidString)")
        for d in dirs {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        return home
    }

    func testConnectAllWiresEveryDetectedAgent() throws {
        let home = try makeHome(dirs: [".codex", ".gemini", ".cursor", ".codeium/windsurf"])
        defer { try? FileManager.default.removeItem(at: home) }

        let results = AgentIntegration.connectAll(mcpBinaryPath: "/opt/contextos-mcp", home: home)
        XCTAssertEqual(Set(results.map(\.agent)), ["Codex", "Gemini CLI", "Cursor", "Windsurf"])

        // Codex: TOML block + AGENTS.md instructions.
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("[mcp_servers.contextos]"))
        XCTAssertTrue(toml.contains("command = \"/opt/contextos-mcp\""))
        let agentsMD = try String(contentsOf: home.appendingPathComponent(".codex/AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(agentsMD.contains("ContextOS"))

        // Gemini: JSON + GEMINI.md.
        let gemini = try String(contentsOf: home.appendingPathComponent(".gemini/settings.json"), encoding: .utf8)
        XCTAssertTrue(gemini.contains("\"contextos\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gemini/GEMINI.md").path))

        // Cursor + Windsurf: JSON MCP configs.
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor/mcp.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codeium/windsurf/mcp_config.json").path))
    }

    func testUndetectedAgentsAreLeftAlone() throws {
        let home = try makeHome(dirs: [".gemini"])   // only Gemini installed
        defer { try? FileManager.default.removeItem(at: home) }

        let results = AgentIntegration.connectAll(mcpBinaryPath: "/opt/contextos-mcp", home: home)
        XCTAssertEqual(results.map(\.agent), ["Gemini CLI"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".cursor").path))
    }

    func testJSONMergePreservesExistingConfig() throws {
        let home = try makeHome(dirs: [".cursor"])
        defer { try? FileManager.default.removeItem(at: home) }
        let mcp = home.appendingPathComponent(".cursor/mcp.json")
        try #"{"mcpServers":{"other":{"command":"/bin/other"}},"theme":"dark"}"#
            .write(to: mcp, atomically: true, encoding: .utf8)

        try AgentIntegration.mergeMCPJSON(at: mcp, mcpBinaryPath: "/opt/contextos-mcp")

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: mcp)) as? [String: Any]
        let servers = root?["mcpServers"] as? [String: Any]
        XCTAssertNotNil(servers?["other"], "pre-existing server must survive the merge")
        XCTAssertNotNil(servers?["contextos"])
        XCTAssertEqual(root?["theme"] as? String, "dark")
    }

    func testTOMLUpsertIsIdempotent() throws {
        let home = try makeHome(dirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let toml = home.appendingPathComponent(".codex/config.toml")
        try "model = \"o3\"\n".write(to: toml, atomically: true, encoding: .utf8)

        try AgentIntegration.upsertTOMLBlock(at: toml, mcpBinaryPath: "/a")
        try AgentIntegration.upsertTOMLBlock(at: toml, mcpBinaryPath: "/b")

        let content = try String(contentsOf: toml, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"o3\""), "existing settings must survive")
        XCTAssertEqual(content.components(separatedBy: "[mcp_servers.contextos]").count - 1, 1,
                       "re-running connect must update the block, not duplicate it")
        XCTAssertTrue(content.contains("command = \"/b\""))
        XCTAssertFalse(content.contains("command = \"/a\""))
    }
}

/// New Korean dev-term dictionary entries actually route to code terms.
final class QueryRefinerDictionaryTests: XCTestCase {
    func testNewKoreanEntries() {
        let refiner = QueryRefiner()
        let cases: [(String, String)] = [
            ("장바구니 버그 고쳐줘", "cart"),
            ("다크모드 추가", "theme"),
            ("삭제가 안 돼", "delete"),
            ("앱이 자꾸 튕겨", "crash"),
            ("최적화 해줘", "optimize"),
        ]
        for (query, expected) in cases {
            let r = refiner.refine(query, vocabulary: [])
            XCTAssertTrue(r.terms.contains(expected), "\(query) → 기대 용어 \(expected), 실제 \(r.terms)")
        }
    }
}
