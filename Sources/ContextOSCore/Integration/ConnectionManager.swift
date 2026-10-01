import Foundation

public enum ManagedAgent: String, Codable, CaseIterable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"
    var key: String { self == .codex ? "codex" : "claude" }
    var files: [String] {
        self == .codex ? [".codex/config.toml", ".codex/AGENTS.md"]
            : [".claude.json", ".claude/settings.json", ".claude/CLAUDE.md"]
    }
}

public struct ConnectionPreview: Identifiable, Sendable {
    public let id: UUID
    public let agent: ManagedAgent
    public let action: String
    public let files: [String]
    public let warnings: [String]
    public var hasChanges: Bool { changes.contains { $0.before != $0.after } }
    let home: URL
    let changes: [SettingsChange]
}

private struct OwnedMutation: Codable, Sendable {
    enum Kind: String, Codable { case json, hook, instruction, tomlValue, tomlSection }
    var kind: Kind
    var file: String
    var path: [String] = []
    var before: Data?
    var after: Data?
}

private struct ConnectionReceipt: Codable {
    var version = 1
    var agent: ManagedAgent
    var mutations: [OwnedMutation]
}

/// All preparation is read-only. Applying a preview is the only mutation point;
/// no external CLI is invoked, so every changed file belongs to the transaction.
public struct ConnectionManager: Sendable {
    public let home: URL
    public let mcpBinaryPath: String
    public let cliBinaryPath: String
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                mcpBinaryPath: String, cliBinaryPath: String) {
        self.home = home.standardizedFileURL
        self.mcpBinaryPath = mcpBinaryPath
        self.cliBinaryPath = cliBinaryPath
    }
    private var transaction: SettingsTransaction { SettingsTransaction(home: home) }
    private func receiptPath(_ agent: ManagedAgent) -> String { ".contextos-backups/owners/\(agent.key).json" }

    public func previewConnect(_ agent: ManagedAgent) throws -> ConnectionPreview {
        var changes: [SettingsChange] = [], mutations: [OwnedMutation] = [], warnings: [String] = []
        let prior = try receipt(agent)
        if let prior {
            // Fail before changing any file when an owned entry was edited.
            for mutation in prior.mutations { try verify(mutation) }
        }
        if agent == .codex {
            let file = agent.files[0]
            var editor = try CodexSettingsEditor(transaction.read(file))
            if try !editor.hasSection {
                try editor.addSection(command: mcpBinaryPath)
                mutations.append(OwnedMutation(kind: .tomlSection, file: file,
                                               after: Data(try editor.ownedSection()!.utf8)))
            } else if let marked = try editor.ownedSection(), Self.onlyManagedTOMLKeys(marked) {
                try editor.set("command", to: String(data: JSONSettingsEditor.encode(mcpBinaryPath), encoding: .utf8)!)
                try editor.set("args", to: "[]")
                mutations.append(OwnedMutation(kind: .tomlSection, file: file,
                                               after: Data(try editor.ownedSection()!.utf8)))
            } else {
                warnings.append("기존 Codex 항목의 다른 키와 주석을 보존합니다. 해제하면 원래 command·args를 복원합니다.")
                for (key, value) in [("command", String(data: try JSONSettingsEditor.encode(mcpBinaryPath), encoding: .utf8)!), ("args", "[]")] {
                    let before = try editor.value(key).map { Data($0.utf8) }
                    try editor.set(key, to: value)
                    mutations.append(OwnedMutation(kind: .tomlValue, file: file, path: [key], before: before, after: Data(value.utf8)))
                }
            }
            changes.append(try transaction.change(file, after: editor.data))
        } else {
            let file = agent.files[0]
            var editor = try JSONSettingsEditor(transaction.read(file), file: ".claude.json")
            let entryPath = ["mcpServers", "contextos"]
            let existing = try editor.value(entryPath)
            if existing == nil || Self.isLegacyMCP(existing) {
                try editor.set(entryPath, to: JSONSettingsEditor.encode(["command": mcpBinaryPath, "args": [String]()]))
                mutations.append(OwnedMutation(kind: .json, file: file, path: entryPath, after: try editor.value(entryPath)))
            } else {
                guard let existing,
                      (try? JSONSerialization.jsonObject(with: existing)) is [String: Any] else { throw SettingsSafetyError.invalid(".claude.json") }
                warnings.append("기존 MCP 항목의 사용자 키를 보존합니다. 해제하면 원래 command·args를 복원합니다.")
                for (key, value) in [("command", try JSONSettingsEditor.encode(mcpBinaryPath)), ("args", try JSONSettingsEditor.encode([String]()))] {
                    let path = entryPath + [key]
                    let before = try editor.value(path)
                    try editor.set(path, to: value)
                    mutations.append(OwnedMutation(kind: .json, file: file, path: path, before: before, after: value))
                }
            }
            changes.append(try transaction.change(file, after: editor.data))
            let settingsFile = agent.files[1]
            var settings = try JSONSettingsEditor(transaction.read(settingsFile), file: "settings.json")
            let hook = try JSONSettingsEditor.encode(["type": "command", "command": cliBinaryPath, "args": ["hook"], "timeout": 20])
            for event in ["UserPromptSubmit", "Stop"] {
                try Self.updateHooks(&settings, event: event, insert: hook, expected: nil)
                mutations.append(OwnedMutation(kind: .hook, file: settingsFile, path: ["hooks", event], after: hook))
            }
            changes.append(try transaction.change(settingsFile, after: settings.data))
        }
        let instructionFile = agent.files.last!
        let original = try SettingsTransaction.text(transaction.read(instructionFile), file: (instructionFile as NSString).lastPathComponent)
        let block = "<!-- ContextOS:begin -->\n" + ClaudeIntegration.instructionBody() + "\n<!-- ContextOS:end -->"
        let instruction = try Self.settingInstruction(original, to: block)
        mutations.append(OwnedMutation(kind: .instruction, file: instructionFile, after: Data(block.utf8)))
        changes.append(try transaction.change(instructionFile, after: Data(instruction.utf8)))
        if let prior {
            for index in mutations.indices {
                if let old = prior.mutations.first(where: { $0.kind == mutations[index].kind && $0.file == mutations[index].file && $0.path == mutations[index].path }) {
                    mutations[index].before = old.before
                }
            }
        }
        let owner = ConnectionReceipt(agent: agent, mutations: mutations)
        changes.append(try transaction.change(receiptPath(agent), after: Self.encodeReceipt(owner)))
        return preview(agent, action: "connect", changes: changes, warnings: warnings)
    }

    public func previewDisconnect(_ agent: ManagedAgent) throws -> ConnectionPreview {
        guard let owner = try receipt(agent) else {
            let data = try transaction.read(agent.files[0])
            if data != nil, (agent == .codex ? try CodexSettingsEditor(data).hasSection : try JSONSettingsEditor(data, file: ".claude.json").value(["mcpServers", "contextos"]) != nil) {
                return preview(agent, action: "disconnect", changes: [], warnings: ["관리 기록이 없는 기존 등록은 보존합니다. 연결 설정을 먼저 확인하면 ContextOS 변경만 안전하게 관리할 수 있습니다."])
            }
            return preview(agent, action: "disconnect", changes: [])
        }
        var edited: [String: Data] = [:]
        for mutation in owner.mutations {
            var data = try edited[mutation.file] ?? transaction.read(mutation.file)
            switch mutation.kind {
            case .json:
                var editor = try JSONSettingsEditor(data, file: (mutation.file as NSString).lastPathComponent)
                let current = try editor.value(mutation.path)
                if !JSONSettingsEditor.equal(current, mutation.before) {
                    guard JSONSettingsEditor.equal(current, mutation.after) else { throw SettingsSafetyError.conflict((mutation.file as NSString).lastPathComponent) }
                    try editor.set(mutation.path, to: mutation.before)
                }
                data = editor.data
            case .hook:
                var editor = try JSONSettingsEditor(data, file: "settings.json")
                try Self.updateHooks(&editor, event: mutation.path.last!, insert: nil, expected: mutation.after)
                data = editor.data
            case .instruction:
                let text = try SettingsTransaction.text(data, file: (mutation.file as NSString).lastPathComponent)
                let current = try Self.instructionRange(text).map { String(text[$0]) }
                guard current == nil || current == mutation.after.flatMap({ String(data: $0, encoding: .utf8) }) else {
                    throw SettingsSafetyError.conflict((mutation.file as NSString).lastPathComponent)
                }
                data = Data(try Self.settingInstruction(text, to: nil).utf8)
            case .tomlValue:
                var editor = try CodexSettingsEditor(data)
                let current = try editor.value(mutation.path[0]).map { Data($0.utf8) }
                if current != mutation.before {
                    guard current == mutation.after else { throw SettingsSafetyError.conflict("config.toml") }
                    try editor.set(mutation.path[0], to: mutation.before.flatMap { String(data: $0, encoding: .utf8) })
                }
                data = editor.data
            case .tomlSection:
                var editor = try CodexSettingsEditor(data)
                if try editor.hasSection {
                    try editor.removeOwnedSection(expected: String(data: mutation.after!, encoding: .utf8)!)
                }
                data = editor.data
            }
            edited[mutation.file] = data
        }
        var changes = try edited.sorted(by: { $0.key < $1.key }).map { try transaction.change($0.key, after: $0.value) }
        changes.append(try transaction.change(receiptPath(agent), after: nil))
        return preview(agent, action: "disconnect", changes: changes)
    }

    public func previewRestore(_ agent: ManagedAgent) throws -> ConnectionPreview {
        let backup = try transaction.latestBackup(agent: agent.rawValue)
        let allowed = Set(agent.files + [receiptPath(agent)])
        var changes: [SettingsChange] = []
        for old in backup.changes {
            guard allowed.contains(old.relativePath) else { throw SettingsSafetyError.invalid("백업") }
            let current = try transaction.read(old.relativePath)
            if current == old.before { continue }
            guard current == old.after else { throw SettingsSafetyError.conflict((old.relativePath as NSString).lastPathComponent) }
            changes.append(SettingsChange(relativePath: old.relativePath, before: current, after: old.before, permissions: old.permissions))
        }
        return preview(agent, action: "restore", changes: changes,
                       warnings: ["최근 연결·해제 직전의 설정을 복구합니다. 이후 사용자 변경이 있으면 덮어쓰지 않고 중단합니다."])
    }

    @discardableResult
    public func apply(_ preview: ConnectionPreview) throws -> URL? {
        guard preview.home == home else { throw SettingsSafetyError.invalid("미리보기") }
        return try transaction.apply(preview.changes, agent: preview.agent.rawValue, action: preview.action)
    }

    private func preview(_ agent: ManagedAgent, action: String, changes: [SettingsChange], warnings: [String] = []) -> ConnectionPreview {
        ConnectionPreview(id: UUID(), agent: agent, action: action,
                          files: changes.filter { $0.before != $0.after && !$0.relativePath.hasPrefix(".contextos-backups/") }.map(\.relativePath),
                          warnings: warnings, home: home, changes: changes)
    }

    private static func encodeReceipt(_ owner: ConnectionReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(owner)
    }

    private func receipt(_ agent: ManagedAgent) throws -> ConnectionReceipt? {
        guard let data = try transaction.read(receiptPath(agent)) else { return nil }
        guard let owner = try? JSONDecoder().decode(ConnectionReceipt.self, from: data), owner.version == 1, owner.agent == agent,
              !owner.mutations.isEmpty,
              owner.mutations.allSatisfy({ mutation in
                  guard let after = mutation.after else { return false }
                  switch mutation.kind {
                  case .json:
                      return agent == .claudeCode && mutation.file == ".claude.json"
                          && [["mcpServers", "contextos"], ["mcpServers", "contextos", "command"], ["mcpServers", "contextos", "args"]].contains(mutation.path)
                          && (try? JSONSerialization.jsonObject(with: after, options: .fragmentsAllowed)) != nil
                  case .hook:
                      return agent == .claudeCode && mutation.file == ".claude/settings.json"
                          && [["hooks", "UserPromptSubmit"], ["hooks", "Stop"]].contains(mutation.path)
                          && (try? JSONSerialization.jsonObject(with: after)) is [String: Any]
                  case .instruction:
                      guard mutation.file == agent.files.last, mutation.path.isEmpty,
                            let text = String(data: after, encoding: .utf8),
                            let range = try? Self.instructionRange(text) else { return false }
                      return range == text.startIndex..<text.endIndex
                  case .tomlValue:
                      return agent == .codex && mutation.file == ".codex/config.toml"
                          && [["command"], ["args"]].contains(mutation.path) && String(data: after, encoding: .utf8) != nil
                  case .tomlSection:
                      guard agent == .codex && mutation.file == ".codex/config.toml", mutation.path.isEmpty,
                            let editor = try? CodexSettingsEditor(after), let section = try? editor.ownedSection() else { return false }
                      return Data(section.utf8) == after
                  }
              }) else { throw SettingsSafetyError.invalid("관리 기록") }
        return owner
    }

    private func verify(_ mutation: OwnedMutation) throws {
        let data = try transaction.read(mutation.file)
        switch mutation.kind {
        case .json:
            guard JSONSettingsEditor.equal(try JSONSettingsEditor(data, file: mutation.file).value(mutation.path), mutation.after) else { throw SettingsSafetyError.conflict((mutation.file as NSString).lastPathComponent) }
        case .tomlValue:
            guard try CodexSettingsEditor(data).value(mutation.path[0]).map({ Data($0.utf8) }) == mutation.after else { throw SettingsSafetyError.conflict("config.toml") }
        case .tomlSection:
            guard try CodexSettingsEditor(data).ownedSection().map({ Data($0.utf8) }) == mutation.after else { throw SettingsSafetyError.conflict("config.toml") }
        case .instruction:
            let text = try SettingsTransaction.text(data, file: mutation.file)
            guard try Self.instructionRange(text).map({ Data(text[$0].utf8) }) == mutation.after else { throw SettingsSafetyError.conflict((mutation.file as NSString).lastPathComponent) }
        case .hook:
            var editor = try JSONSettingsEditor(data, file: "settings.json")
            try Self.updateHooks(&editor, event: mutation.path.last!, insert: mutation.after, expected: mutation.after)
        }
    }

    private static func isLegacyMCP(_ data: Data?) -> Bool {
        guard let data, let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = value["command"] as? String, (command as NSString).lastPathComponent == "contextos-mcp",
              value["args"] as? [String] == [], Set(value.keys).isSubset(of: ["command", "args", "type"]) else { return false }
        return value["type"] == nil || value["type"] as? String == "stdio"
    }

    private static func onlyManagedTOMLKeys(_ section: String) -> Bool {
        section.components(separatedBy: "\n").allSatisfy { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("[")
                || trimmed.range(of: #"^(command|args)\s*="#, options: .regularExpression) != nil
        }
    }

    static func instructionRange(_ text: String) throws -> Range<String.Index>? {
        let begin = "<!-- ContextOS:begin -->", end = "<!-- ContextOS:end -->"
        let begins = text.components(separatedBy: begin).count - 1
        let ends = text.components(separatedBy: end).count - 1
        guard begins == ends, begins <= 1 else { throw SettingsSafetyError.invalid("지침 파일") }
        guard let a = text.range(of: begin), let b = text.range(of: end), a.upperBound <= b.lowerBound else {
            if begins > 0 { throw SettingsSafetyError.invalid("지침 파일") }
            return nil
        }
        return a.lowerBound..<b.upperBound
    }

    static func settingInstruction(_ text: String, to block: String?) throws -> String {
        var text = text
        if let range = try instructionRange(text) { text.replaceSubrange(range, with: block ?? "") }
        else if let block { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + block + "\n" }
        return text
    }

    private static func hookIdentity(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "command", let command = entry["command"] as? String,
              (command as NSString).lastPathComponent == "contextos", entry["args"] as? [String] == ["hook"] else { return false }
        return true
    }

    static func updateHooks(_ editor: inout JSONSettingsEditor, event: String, insert: Data?, expected: Data?) throws {
        let path = ["hooks", event]
        let current = try editor.value(path)
        var groups: [[String: Any]] = []
        if let current {
            guard let decoded = try JSONSerialization.jsonObject(with: current) as? [[String: Any]] else { throw SettingsSafetyError.invalid("settings.json") }
            groups = decoded
        }
        var output: [[String: Any]] = []
        var foundExpected = false
        for var group in groups {
            guard let entries = group["hooks"] as? [[String: Any]] else { throw SettingsSafetyError.invalid("settings.json") }
            var kept: [[String: Any]] = []
            for entry in entries {
                if hookIdentity(entry) {
                    let encoded = try JSONSettingsEditor.encode(entry)
                    if let expected {
                        guard JSONSettingsEditor.equal(encoded, expected) else { throw SettingsSafetyError.conflict("settings.json") }
                        foundExpected = true
                    } else {
                        guard Set(entry.keys).isSubset(of: ["type", "command", "args", "timeout"]) else { throw SettingsSafetyError.conflict("settings.json") }
                    }
                } else { kept.append(entry) }
            }
            group["hooks"] = kept
            if !kept.isEmpty || Set(group.keys) != ["hooks"] { output.append(group) }
        }
        if let insert {
            if expected != nil && !foundExpected { throw SettingsSafetyError.conflict("settings.json") }
            output.append(["hooks": [try JSONSerialization.jsonObject(with: insert)]])
        }
        if current == nil && output.isEmpty { return }
        try editor.set(path, to: output.isEmpty ? nil : JSONSettingsEditor.encode(output))
    }
}
