import XCTest
import Foundation
@testable import ContextOSCore

final class SafeConnectionTests: XCTestCase {
    private var home: URL!
    private var manager: ConnectionManager { ConnectionManager(home: home, mcpBinaryPath: "/audit/contextos-mcp", cliBinaryPath: "/audit/contextos") }
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("contextos-safe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    @discardableResult private func write(_ path: String, _ text: String) throws -> URL {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
    private func read(_ path: String) throws -> String { try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8) }
    private func json(_ path: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(path))) as! [String: Any] }

    func testPreviewAndCancelDoNotWriteAnything() throws {
        let original = "# user comment\nmodel = \"audit\"\n"
        try write(".codex/config.toml", original)
        let preview = try manager.previewConnect(.codex)
        XCTAssertTrue(preview.hasChanges)
        XCTAssertEqual(try read(".codex/config.toml"), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".contextos-backups").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
    }

    func testMalformedClaudeSettingsAbortBeforeAnyChange() throws {
        try write(".claude.json", "{\"user_key\":\"DUMMY_PRIVATE_VALUE\"}\n")
        let broken = "{\"user_key\":\"DUMMY_PRIVATE_VALUE\","
        let file = try write(".claude/settings.json", broken)
        XCTAssertThrowsError(try manager.previewConnect(.claudeCode))
        XCTAssertThrowsError(try ClaudeIntegration.installPromptHook(at: file, contextosBinaryPath: "/audit/contextos"))
        XCTAssertEqual(try read(".claude/settings.json"), broken)
        XCTAssertEqual(try read(".claude.json"), "{\"user_key\":\"DUMMY_PRIVATE_VALUE\"}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".contextos-backups").path))
    }

    func testDuplicateJSONKeysAndJSONCommentsFailClosed() throws {
        for content in [#"{"mcpServers":{},"mcpServers":{}}"#, "{\n// keep this comment\n\"other\":true\n}"] {
            try write(".claude.json", content)
            XCTAssertThrowsError(try manager.previewConnect(.claudeCode))
            XCTAssertEqual(try read(".claude.json"), content)
        }
    }

    func testClaudeConnectRepeatDisconnectAndRestoreKeepUserSettings() throws {
        try write(".claude.json", "{\n  \"user_key\"  : \"DUMMY_PRIVATE_VALUE\",\n  \"mcpServers\": {\"other\": {\"command\":\"/audit/other\"}}\n}\n")
        try write(".claude/settings.json", #"{"other":true,"hooks":{"Stop":[{"matcher":"keep","hooks":[{"type":"command","command":"/audit/other"},{"type":"command","command":"/old/contextos","args":["hook"],"timeout":20}]}]}}"#)
        try write(".claude/CLAUDE.md", "# User rules\nkeep exactly\n")
        let preview = try manager.previewConnect(.claudeCode)
        XCTAssertFalse(preview.warnings.joined().contains("DUMMY_PRIVATE_VALUE"))
        try manager.apply(preview)
        XCTAssertTrue(try read(".claude.json").contains("\"user_key\"  : \"DUMMY_PRIVATE_VALUE\""))
        XCTAssertFalse(try manager.previewConnect(.claudeCode).hasChanges)
        XCTAssertTrue(try read(".claude/CLAUDE.md").hasPrefix("# User rules\nkeep exactly\n"))
        try manager.apply(manager.previewDisconnect(.claudeCode))
        let root = try json(".claude.json")
        XCTAssertNil((root["mcpServers"] as? [String: Any])?["contextos"])
        XCTAssertNotNil((root["mcpServers"] as? [String: Any])?["other"])
        XCTAssertTrue(try read(".claude/settings.json").contains("/audit/other"))
        XCTAssertTrue(try read(".claude/settings.json").contains("\"matcher\":\"keep\""))
        XCTAssertFalse(try read(".claude/settings.json").contains("/audit/contextos"))
        XCTAssertFalse(try read(".claude/CLAUDE.md").contains("ContextOS:begin"))
        XCTAssertFalse(try manager.previewDisconnect(.claudeCode).hasChanges)
        try manager.apply(manager.previewRestore(.claudeCode))
        XCTAssertNotNil((try json(".claude.json")["mcpServers"] as? [String: Any])?["contextos"])
        XCTAssertFalse(try manager.previewRestore(.claudeCode).hasChanges)
    }

    func testUnmarkedCodexTableIsUpdatedOnceAndUserKeysSurviveDisconnect() throws {
        let original = "# user top comment\nmodel = \"audit\"\n[mcp_servers.contextos] # keep header\ncommand = '/audit/user-server' # keep command comment\nargs = [\"--user-option\"]\nenabled = true\n[mcp_servers.contextos.env]\nUSER_KEY = \"DUMMY_PRIVATE_VALUE\"\n[mcp_servers.other]\ncommand = \"other\"\n"
        try write(".codex/config.toml", original)
        try manager.apply(manager.previewConnect(.codex))
        var connected = try read(".codex/config.toml")
        XCTAssertEqual(connected.components(separatedBy: "[mcp_servers.contextos]").count - 1, 1)
        XCTAssertTrue(connected.contains("# keep header"))
        XCTAssertTrue(connected.contains("# keep command comment"))
        XCTAssertTrue(connected.contains("USER_KEY = \"DUMMY_PRIVATE_VALUE\""))
        XCTAssertFalse(try manager.previewConnect(.codex).hasChanges)
        try manager.apply(manager.previewDisconnect(.codex))
        connected = try read(".codex/config.toml")
        XCTAssertTrue(connected.contains("'/audit/user-server'"))
        XCTAssertTrue(connected.contains("[\"--user-option\"]"))
        XCTAssertTrue(connected.contains("USER_KEY = \"DUMMY_PRIVATE_VALUE\""))
        XCTAssertTrue(connected.contains("[mcp_servers.other]"))
        XCTAssertFalse(try manager.previewDisconnect(.codex).hasChanges)
    }

    func testQuotedCodexTableAndEscapedExecutablePath() throws {
        try write(".codex/config.toml", "[\"mcp_servers\".'contextos']\ncommand = \"old\"\nargs = []\n")
        let custom = ConnectionManager(home: home, mcpBinaryPath: "/audit/a \"quote\"/contextos-mcp", cliBinaryPath: "/audit/contextos")
        try custom.apply(custom.previewConnect(.codex))
        let content = try read(".codex/config.toml")
        XCTAssertEqual(content.components(separatedBy: "contextos']").count - 1, 1)
        XCTAssertTrue(content.contains("\\\"quote\\\""))
    }

    func testDuplicateAndMalformedCodexTablesAreNotRewritten() throws {
        for content in ["[mcp_servers.contextos]\ncommand=\"a\"\n[mcp_servers.contextos]\ncommand=\"b\"\n", "# ContextOS:begin\n[mcp_servers.contextos]\ncommand=\"a\"\n", "[mcp_servers.contextos]\ncommand = \"unterminated\nargs=[]\n"] {
            try write(".codex/config.toml", content)
            XCTAssertThrowsError(try manager.previewConnect(.codex))
            XCTAssertEqual(try read(".codex/config.toml"), content)
        }
    }

    func testFakeTableInsideMultilineStringIsNotTouched() throws {
        let userText = "description = '''\n[mcp_servers.contextos]\ncommand = \"inside documentation\"\n'''\n"
        try write(".codex/config.toml", userText)
        try manager.apply(manager.previewConnect(.codex))
        XCTAssertTrue(try read(".codex/config.toml").hasPrefix(userText))
        try manager.apply(manager.previewDisconnect(.codex))
        XCTAssertEqual(try read(".codex/config.toml"), userText)
    }

    func testDisconnectRefusesUserEditedOwnedFields() throws {
        try manager.apply(manager.previewConnect(.claudeCode))
        var editor = try JSONSettingsEditor(Data(try read(".claude.json").utf8), file: ".claude.json")
        try editor.set(["mcpServers", "contextos", "new_user_key"], to: JSONSettingsEditor.encode("keep"))
        try write(".claude.json", String(data: editor.data, encoding: .utf8)!)
        let before = try read(".claude.json")
        XCTAssertThrowsError(try manager.previewDisconnect(.claudeCode))
        XCTAssertEqual(try read(".claude.json"), before)
    }

    func testUnownedRegistrationIsNeverDeleted() throws {
        let content = "[mcp_servers.contextos]\ncommand=\"/audit/user-tool\"\nargs=[]\n"
        try write(".codex/config.toml", content)
        XCTAssertFalse(try manager.previewDisconnect(.codex).hasChanges)
        XCTAssertEqual(try read(".codex/config.toml"), content)
    }

    func testCorruptManagementRecordFailsClosed() throws {
        try write(".contextos-backups/owners/codex.json", #"{"version":1,"agent":"Codex","mutations":[{"kind":"tomlValue","file":".codex/config.toml","path":[]}] }"#)
        XCTAssertThrowsError(try manager.previewDisconnect(.codex))
        XCTAssertThrowsError(try manager.previewConnect(.codex))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testConcurrentEditAfterPreviewAbortsAllWrites() throws {
        try write(".codex/config.toml", "# original\n")
        let preview = try manager.previewConnect(.codex)
        try write(".codex/config.toml", "# concurrent user edit\n")
        XCTAssertThrowsError(try manager.apply(preview))
        XCTAssertEqual(try read(".codex/config.toml"), "# concurrent user edit\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
    }

    func testPartialFailureRollsBackEarlierFiles() throws {
        try write("a.json", "old-a"); try write("b.json", "old-b")
        let transaction = SettingsTransaction(home: home)
        let edits = try [transaction.change("a.json", after: Data("new-a".utf8)), transaction.change("b.json", after: Data("new-b".utf8))]
        XCTAssertThrowsError(try transaction.apply(edits, agent: "test", action: "connect", beforeWrite: { index in
            if index == 1 { throw CocoaError(.fileWriteNoPermission) }
        }))
        XCTAssertEqual(try read("a.json"), "old-a")
        XCTAssertEqual(try read("b.json"), "old-b")
    }

    func testRollbackDoesNotOverwriteConcurrentChanges() throws {
        try write("a.json", "old-a"); try write("b.json", "old-b")
        let transaction = SettingsTransaction(home: home)
        let edits = try [transaction.change("a.json", after: Data("new-a".utf8)), transaction.change("b.json", after: Data("new-b".utf8))]
        XCTAssertThrowsError(try transaction.apply(edits, agent: "test", action: "connect", beforeWrite: { index in
            if index == 1 { try self.write("a.json", "concurrent-user-edit"); throw CocoaError(.fileWriteNoPermission) }
        })) { error in XCTAssertEqual(error as? SettingsSafetyError, .rollbackConflict) }
        XCTAssertEqual(try read("a.json"), "concurrent-user-edit")
    }

    func testRestoreIsByteExactAndRefusesLaterUserEdit() throws {
        let original = "# user comment\nmodel = \"audit\"\n"
        try write(".codex/config.toml", original)
        try manager.apply(manager.previewConnect(.codex))
        try manager.apply(manager.previewRestore(.codex))
        XCTAssertEqual(try read(".codex/config.toml"), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/AGENTS.md").path))
        try manager.apply(manager.previewConnect(.codex))
        try write(".codex/config.toml", try read(".codex/config.toml") + "# user changed later\n")
        XCTAssertThrowsError(try manager.previewRestore(.codex))
        XCTAssertTrue(try read(".codex/config.toml").contains("# user changed later"))
    }

    func testBackupsArePrivateAndDoNotAppearInPreview() throws {
        try write(".claude.json", #"{"user_key":"DUMMY_PRIVATE_VALUE"}"#)
        let backup = try XCTUnwrap(manager.apply(manager.previewConnect(.claudeCode)))
        let attrs = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
        let rootAttrs = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".contextos-backups").path)
        XCTAssertEqual((rootAttrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o700)
        XCTAssertTrue(String(data: try Data(contentsOf: backup), encoding: .utf8)!.contains("before"))
    }

    func testSymlinkedConfigAndDirectoryAreRejected() throws {
        let outside = try write("outside.json", "{}")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try manager.previewConnect(.claudeCode))
        XCTAssertEqual(try read("outside.json"), "{}")
    }
}
