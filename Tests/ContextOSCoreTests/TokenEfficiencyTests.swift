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

    func testQueryAutoRefreshesStaleIndex() throws {
        // Regression: ensureIndexed used to skip when the DB existed, so a file
        // added after the first query stayed invisible. A query must now see new
        // symbols without any manual reindex.
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()

        _ = try service.relevantContext(query: "login", projectRoot: root, tokenBudget: 8000) // builds index

        try "def transfer_funds(dst, amount):\n    return amount\n"
            .write(to: root.appendingPathComponent("src/wallet.py"), atomically: true, encoding: .utf8)

        let sel = try service.relevantContext(query: "transfer_funds", projectRoot: root, tokenBudget: 8000)
        XCTAssertTrue(sel.included.contains { $0.path == "src/wallet.py" },
                      "a symbol added after the first query must be found without a manual reindex")
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

    func testMemoryEntriesExpireAfterTTL() {
        // After the agent compacts its context, earlier bodies are gone from
        // its memory — the TTL guarantees we eventually resend rather than
        // withholding a file forever.
        let memory = SessionMemory(ttl: 60)
        memory.markServed(project: "/p", path: "a.swift", bodyHash: "h1")
        XCTAssertTrue(memory.isUnchanged(project: "/p", path: "a.swift", bodyHash: "h1"))
        let later = Date(timeIntervalSinceNow: 61)
        XCTAssertFalse(memory.isUnchanged(project: "/p", path: "a.swift", bodyHash: "h1", now: later))
    }

    func testFreshBypassEquivalent() throws {
        // fresh=true in the MCP layer passes memory=nil — verify a nil memory
        // resends everything even when a populated memory exists.
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()
        let memory = SessionMemory()

        _ = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: memory)
        let fresh = try service.optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 8000, memory: nil)
        XCTAssertEqual(fresh.skippedUnchanged, 0)
        XCTAssertTrue(fresh.bundle.contains("def login"))
    }

    func testExcludedFilesGetSignatureOutline() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // Make both bodies too large, leaving room for a useful outline.
        // An outline is optional when delivered bodies exhaust the budget.
        for path in ["src/login.py", "src/auth.py"] {
            try ("def login():\n    return '" + String(repeating: "payload", count: 200) + "'\n")
                .write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let (selection, bundle, _, _, _) = try ContextService().optimizedBundle(
            query: "fix login", projectRoot: root, tokenBudget: 100)
        XCTAssertFalse(selection.excluded.isEmpty)
        XCTAssertTrue(bundle.contains("시그니처 목차"))
        XCTAssertLessThanOrEqual(TokenEstimator().estimate(text: bundle), 100)
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

/// Detection must report concrete configuration evidence and never turn an
/// unobserved transcript into a made-up zero-token total.
final class AgentDetectorTests: XCTestCase {

    private func makeHome(dirs: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-detector-\(UUID().uuidString)")
        for dir in dirs {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        return home
    }

    private func agent(_ name: String, in agents: [DetectedAgent]) throws -> DetectedAgent {
        try XCTUnwrap(agents.first { $0.name == name })
    }

    func testReportsOnlyExplicitContextOSConfigurationsAndRecordedUsage() throws {
        let home = try makeHome(dirs: [".claude/projects", ".codex", ".gemini", ".cursor", ".continue"])
        defer { try? FileManager.default.removeItem(at: home) }

        try #"{"mcpServers":{"contextos":{"command":"/opt/contextos"}}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try "[mcp_servers.contextos]\ncommand = \"/opt/contextos\"\n"
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"other":{}}}"#
            .write(to: home.appendingPathComponent(".gemini/settings.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers":{"contextos":{"command":"/opt/contextos"}}}"#
            .write(to: home.appendingPathComponent(".cursor/mcp.json"), atomically: true, encoding: .utf8)

        var usage = AgentUsageSnapshot()
        usage.availableAgents = ["Claude Code", "Codex"]
        usage.byAgent = ["Claude Code": 123, "Codex": 456]
        let agents = AgentDetector.detect(home: home, usage: usage)

        XCTAssertTrue(try agent("Claude Code", in: agents).connection.isConfigured)
        XCTAssertEqual(try agent("Claude Code", in: agents).usage, .reported(tokens: 123))
        XCTAssertTrue(try agent("Codex", in: agents).connection.isConfigured)
        XCTAssertEqual(try agent("Codex", in: agents).usage, .reported(tokens: 456))
        XCTAssertEqual(try agent("Gemini CLI", in: agents).connection,
                       .notConfigured(path: home.appendingPathComponent(".gemini/settings.json").path))
        XCTAssertTrue(try agent("Cursor", in: agents).connection.isConfigured)
        XCTAssertEqual(try agent("Continue", in: agents).connection, .unsupported)
    }

    func testMissingTranscriptIsShownAsMissingRatherThanZero() throws {
        let home = try makeHome(dirs: [".codex"])
        defer { try? FileManager.default.removeItem(at: home) }

        var usage = AgentUsageSnapshot()
        usage.availableAgents = ["Claude Code"] // Codex has no readable session file.
        let codex = try agent("Codex", in: AgentDetector.detect(home: home, usage: usage))
        XCTAssertEqual(codex.usage, .noLocalRecord)
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
