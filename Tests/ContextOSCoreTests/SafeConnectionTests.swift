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

    func testQuotedTOMLWhitespaceDoesNotAliasManagedTable() throws {
        for header in ["[' mcp_servers '.contextos]", "[mcp_servers.\" contextos \"]"] {
            let original = header + "\ncommand = \"/user/foreign\"\nargs = [\"keep\"]\n"
            try write(".codex/config.toml", original)
            let preview = try manager.previewConnect(.codex)
            try manager.apply(preview)
            XCTAssertTrue(try read(".codex/config.toml").hasPrefix(original))
            XCTAssertTrue(try read(".codex/config.toml").contains("[mcp_servers.contextos]"))
            try manager.apply(manager.previewDisconnect(.codex))
            XCTAssertEqual(try read(".codex/config.toml"), original)
        }
    }

    func testUnclosedUnrelatedTOMLStringFailsBeforeAnyWrite() throws {
        for original in ["model = \"unfinished\n", "model = 'unfinished\n"] {
            try write(".codex/config.toml", original)
            XCTAssertThrowsError(try manager.previewConnect(.codex))
            XCTAssertEqual(try read(".codex/config.toml"), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".contextos-backups").path))
        }
    }

    func testLegacyMarkedCodexToolApprovalsSurviveConnectAndDisconnect() throws {
        let original = "# ContextOS:begin\n[mcp_servers.contextos]\ncommand = \"/user/contextos-mcp\"\nargs = [\"--user\"]\n\n[mcp_servers.contextos.tools.read_optimized]\napproval_mode = \"prompt\"\ncommand = \"USER_TOOL\"\nargs = [\"keep\"]\n# ContextOS:end\n"
        try write(".codex/config.toml", original)
        let preview = try manager.previewConnect(.codex)
        XCTAssertEqual(try read(".codex/config.toml"), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".contextos-backups").path))
        try manager.apply(preview)
        let connected = try read(".codex/config.toml")
        XCTAssertTrue(connected.contains("command = \"/audit/contextos-mcp\"\nargs = []"))
        XCTAssertTrue(connected.contains("approval_mode = \"prompt\"\ncommand = \"USER_TOOL\"\nargs = [\"keep\"]"))
        XCTAssertFalse(try manager.previewConnect(.codex).hasChanges)
        try manager.apply(manager.previewDisconnect(.codex))
        XCTAssertEqual(try read(".codex/config.toml"), original)
    }

    func testNewChildTablesPreventRemovalOfAnOwnedCodexRegistration() throws {
        for inside in [true, false] {
            let temporary = home.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let custom = ConnectionManager(home: temporary, mcpBinaryPath: "/audit/contextos-mcp", cliBinaryPath: "/audit/contextos")
            try custom.apply(custom.previewConnect(.codex))
            let file = temporary.appendingPathComponent(".codex/config.toml")
            let source = try String(contentsOf: file, encoding: .utf8)
            let child = "[mcp_servers.contextos.tools.read_optimized]\napproval_mode = \"prompt\"\n"
            let extended = inside ? source.replacingOccurrences(of: "# ContextOS:end", with: child + "# ContextOS:end") : source + child
            try extended.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try custom.previewDisconnect(.codex))
            XCTAssertThrowsError(try custom.previewConnect(.codex))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), extended)
        }
    }

    func testForeignTablesInsideContextOSMarkersRemainRejected() throws {
        let source = "# ContextOS:begin\n[mcp_servers.contextos]\ncommand = \"old\"\nargs = []\n[mcp_servers.other]\ncommand = \"USER_TOOL\"\n# ContextOS:end\n"
        try write(".codex/config.toml", source)
        XCTAssertThrowsError(try manager.previewConnect(.codex))
        XCTAssertEqual(try read(".codex/config.toml"), source)
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

    func testConcurrentEditWhilePreviewIsBuiltCannotBecomeItsBaseline() throws {
        try write(".claude.json", #"{"keep":"original"}"#)
        let transaction = SettingsTransaction(home: home)
        var snapshot = SettingsSnapshot(transaction: transaction)
        var editor = try JSONSettingsEditor(snapshot.read(".claude.json"), file: ".claude.json")
        try editor.set(["contextos"], to: JSONSettingsEditor.encode(true))
        // Another editor saves after parsing but before the preview is ready.
        let concurrent = #"{"keep":"concurrent-user-edit"}"#
        try write(".claude.json", concurrent)
        let change = try snapshot.change(".claude.json", after: editor.data)
        XCTAssertThrowsError(try transaction.apply([change], agent: "test", action: "connect"))
        XCTAssertEqual(try read(".claude.json"), concurrent)
    }

    func testPreviewSnapshotRemembersInitiallyMissingFile() throws {
        let transaction = SettingsTransaction(home: home)
        var snapshot = SettingsSnapshot(transaction: transaction)
        XCTAssertNil(try snapshot.read(".codex/AGENTS.md"))
        try write(".codex/AGENTS.md", "Concurrent new user rules\n")
        let change = try snapshot.change(".codex/AGENTS.md", after: Data("ContextOS rules\n".utf8))
        XCTAssertNil(change.before)
        XCTAssertThrowsError(try transaction.apply([change], agent: "test", action: "connect"))
        XCTAssertEqual(try read(".codex/AGENTS.md"), "Concurrent new user rules\n")
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

    func testInterruptedSettingsApplyCanBeExplicitlyRestored() throws {
        try write(".claude.json", "{}\n")
        try write(".claude/settings.json", "{}\n")
        let preview = try manager.previewConnect(.claudeCode)
        let backup = SettingsBackup(id: UUID(), agent: ManagedAgent.claudeCode.rawValue,
                                    action: "connect", date: Date(), committed: false,
                                    changes: preview.changes.filter { $0.before != $0.after })
        let backupFile = ".contextos-backups/history/" + backup.id.uuidString + ".json"
        try write(backupFile, String(data: JSONEncoder().encode(backup), encoding: .utf8)!)
        // A stopped process completed the first setting but never the others
        // or ownership receipt. Model that state without crashing the tests.
        let first = try XCTUnwrap(backup.changes.first)
        try write(first.relativePath, String(data: try XCTUnwrap(first.after), encoding: .utf8)!)
        let restore = try manager.previewRestore(.claudeCode)
        XCTAssertTrue(restore.hasChanges)
        XCTAssertTrue(restore.warnings.joined().contains("중단"))
        try manager.apply(restore)
        XCTAssertEqual(try read(".claude.json"), "{}\n")
        XCTAssertEqual(try read(".claude/settings.json"), "{}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".contextos-backups/owners/claude.json").path))
    }

    func testInterruptedApplyRestoreRefusesConcurrentUserChanges() throws {
        try write(".claude.json", "{}\n")
        try write(".claude/settings.json", "{}\n")
        let preview = try manager.previewConnect(.claudeCode)
        let backup = SettingsBackup(id: UUID(), agent: ManagedAgent.claudeCode.rawValue,
                                    action: "connect", date: Date(), committed: false,
                                    changes: preview.changes.filter { $0.before != $0.after })
        try write(".contextos-backups/history/" + backup.id.uuidString + ".json",
                  String(data: JSONEncoder().encode(backup), encoding: .utf8)!)
        let first = try XCTUnwrap(backup.changes.first)
        try write(first.relativePath, String(data: try XCTUnwrap(first.after), encoding: .utf8)!)
        let concurrent = #"{"user_key":"new-user-setting"}"#
        try write(".claude/settings.json", concurrent)
        XCTAssertThrowsError(try manager.previewRestore(.claudeCode))
        XCTAssertEqual(try read(".claude/settings.json"), concurrent)
        XCTAssertEqual(try read(first.relativePath), String(data: first.after!, encoding: .utf8)!)
    }

    func testRolledBackAttemptDoesNotHidePreviousRestorableBackup() throws {
        let original = "model = \"user-model\"\n"
        try write(".codex/config.toml", original)
        try manager.apply(manager.previewConnect(.codex))
        let rolledBack = try manager.previewDisconnect(.codex)
        let backup = SettingsBackup(id: UUID(), agent: ManagedAgent.codex.rawValue,
                                    action: "disconnect", date: Date().addingTimeInterval(1), committed: false,
                                    changes: rolledBack.changes.filter { $0.before != $0.after })
        try write(".contextos-backups/history/" + backup.id.uuidString + ".json",
                  String(data: JSONEncoder().encode(backup), encoding: .utf8)!)
        // All files still equal the interrupted attempt's 'before' bytes.
        try manager.apply(manager.previewRestore(.codex))
        XCTAssertEqual(try read(".codex/config.toml"), original)
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
