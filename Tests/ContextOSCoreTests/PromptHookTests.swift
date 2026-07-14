import XCTest
@testable import ContextOSCore

final class PromptContextTests: XCTestCase {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try """
        def login(user, password):
            return check(user, password)
        def check(user, password):
            return True
        """.write(to: root.appendingPathComponent("src/login.py"), atomically: true, encoding: .utf8)
        try "def charge(amount):\n    return amount\n"
            .write(to: root.appendingPathComponent("src/billing.py"), atomically: true, encoding: .utf8)
        return root
    }

    func testPromptContextListsRelevantFilesWithSymbols() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try ContextService().promptContext(query: "fix login", projectRoot: root)
        let hint = try XCTUnwrap(result).text
        XCTAssertTrue(hint.contains("[ContextOS]"))
        XCTAssertTrue(hint.contains("src/login.py"))
        XCTAssertTrue(hint.contains("login"))            // a key symbol is listed
        XCTAssertTrue(hint.contains("read_optimized"))   // points at the body tool
        XCTAssertFalse(hint.contains("src/billing.py"))  // unrelated file omitted
    }

    func testPromptContextNilWhenNothingRelevant() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        // A query with no lexical/graph signal in this project.
        let result = try ContextService().promptContext(query: "quantum chromodynamics", projectRoot: root)
        XCTAssertNil(result)
    }

    func testPromptContextExcludesPreviouslyInjectedFiles() throws {
        let root = try makeProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ContextService()

        let first = try XCTUnwrap(service.promptContext(query: "fix login", projectRoot: root))
        XCTAssertTrue(first.text.contains("src/login.py"))

        // Feeding the previous turn's files as `excluding` drops them — nothing
        // new to inject, so a repeat prompt injects nothing.
        let second = try service.promptContext(
            query: "fix login", projectRoot: root, excluding: Set(first.allPaths))
        XCTAssertNil(second)
    }
}

final class PromptHookInstallTests: XCTestCase {

    private func tempSettings() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("contextos-settings-\(UUID().uuidString)")
            .appendingPathComponent("settings.json")
    }

    func testInstallCreatesUserPromptSubmitHook() throws {
        let url = tempSettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let hadPrior = try ClaudeIntegration.installPromptHook(at: url, contextosBinaryPath: "/opt/ctx/contextos")
        XCTAssertFalse(hadPrior)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let ups = ((root?["hooks"] as? [String: Any])?["UserPromptSubmit"]) as? [[String: Any]]
        let entry = ((ups?.first?["hooks"]) as? [[String: Any]])?.first
        XCTAssertEqual(entry?["command"] as? String, "/opt/ctx/contextos")
        XCTAssertEqual(entry?["args"] as? [String], ["hook"])
    }

    func testInstallPreservesOtherSettingsAndHooks() throws {
        let url = tempSettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"""
        {"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/other/tool"}]}],"Stop":[{"hooks":[{"type":"command","command":"/beep"}]}]}}
        """#.write(to: url, atomically: true, encoding: .utf8)

        try ClaudeIntegration.installPromptHook(at: url, contextosBinaryPath: "/opt/ctx/contextos")

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(root?["model"] as? String, "opus")
        let hooks = root?["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["Stop"], "other hook events must survive")
        let ups = hooks?["UserPromptSubmit"] as? [[String: Any]]
        XCTAssertEqual(ups?.count, 2, "existing UserPromptSubmit hook preserved + ours appended")
        let commands = ups?.compactMap { (($0["hooks"] as? [[String: Any]])?.first)?["command"] as? String }
        XCTAssertEqual(Set(commands ?? []), ["/other/tool", "/opt/ctx/contextos"])
    }

    func testReinstallIsIdempotent() throws {
        let url = tempSettings()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try ClaudeIntegration.installPromptHook(at: url, contextosBinaryPath: "/opt/ctx/contextos")
        let hadPrior = try ClaudeIntegration.installPromptHook(at: url, contextosBinaryPath: "/new/path/contextos")
        XCTAssertTrue(hadPrior, "second run should report it replaced an existing entry")

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let ups = ((root?["hooks"] as? [String: Any])?["UserPromptSubmit"]) as? [[String: Any]]
        XCTAssertEqual(ups?.count, 1, "must update in place, not stack duplicate ContextOS hooks")
        let cmd = (((ups?.first?["hooks"]) as? [[String: Any]])?.first)?["command"] as? String
        XCTAssertEqual(cmd, "/new/path/contextos")
    }
}
