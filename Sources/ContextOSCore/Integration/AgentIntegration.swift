import Foundation

/// Wires ContextOS into every AI coding agent installed on this machine — not
/// just Claude Code. Each agent gets (a) the `contextos` MCP server registered
/// in its own config format, and (b) where the agent reads a global instruction
/// file, the same "use ContextOS first" rules Claude Code gets.
///
/// Only agents actually detected (their config directory exists) are touched.
/// Every write is idempotent: JSON configs merge one key, marked blocks replace
/// themselves on re-run.
public enum AgentIntegration {

    /// What `connect` did for one agent.
    public struct ConnectionResult: Sendable {
        public var agent: String
        /// Config file the MCP server was registered in.
        public var mcpConfigPath: String
        /// Instruction file installed, when the agent supports one globally.
        public var instructionPath: String?
    }

    /// Connect every detected agent (best-effort; an agent whose config can't
    /// be written is skipped rather than failing the rest).
    public static func connectAll(
        mcpBinaryPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ConnectionResult] {
        var results: [ConnectionResult] = []
        if let r = try? connectCodex(home: home, mcpBinaryPath: mcpBinaryPath) { results.append(r) }
        if let r = try? connectGemini(home: home, mcpBinaryPath: mcpBinaryPath) { results.append(r) }
        if let r = try? connectCursor(home: home, mcpBinaryPath: mcpBinaryPath) { results.append(r) }
        if let r = try? connectWindsurf(home: home, mcpBinaryPath: mcpBinaryPath) { results.append(r) }
        return results
    }

    /// Connect one agent, by the name `AgentDetector` reports for it. Nil when
    /// it isn't installed here or ContextOS has no adapter for it. Claude Code is
    /// `ClaudeIntegration.connect`.
    public static func connect(
        agent: String,
        mcpBinaryPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ConnectionResult? {
        switch agent {
        case "Codex": return try connectCodex(home: home, mcpBinaryPath: mcpBinaryPath)
        case "Gemini CLI": return try connectGemini(home: home, mcpBinaryPath: mcpBinaryPath)
        case "Cursor": return try connectCursor(home: home, mcpBinaryPath: mcpBinaryPath)
        case "Windsurf": return try connectWindsurf(home: home, mcpBinaryPath: mcpBinaryPath)
        default: return nil
        }
    }

    // MARK: - Per-agent wiring

    /// Codex CLI: `~/.codex/config.toml` ([mcp_servers.contextos]) + `~/.codex/AGENTS.md`.
    static func connectCodex(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        let dir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let manager = ConnectionManager(home: home, mcpBinaryPath: mcpBinaryPath,
                                        cliBinaryPath: (mcpBinaryPath as NSString).deletingLastPathComponent + "/contextos")
        try manager.apply(manager.previewConnect(.codex))
        return ConnectionResult(agent: "Codex", mcpConfigPath: dir.appendingPathComponent("config.toml").path,
                                instructionPath: dir.appendingPathComponent("AGENTS.md").path)
    }

    /// Gemini CLI: `~/.gemini/settings.json` (mcpServers) + `~/.gemini/GEMINI.md`.
    static func connectGemini(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        let dir = home.appendingPathComponent(".gemini")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let settings = dir.appendingPathComponent("settings.json")
        try mergeMCPJSON(at: settings, mcpBinaryPath: mcpBinaryPath)

        let geminiMD = dir.appendingPathComponent("GEMINI.md")
        try ClaudeIntegration.installInstruction(at: geminiMD)

        return ConnectionResult(agent: "Gemini CLI", mcpConfigPath: settings.path, instructionPath: geminiMD.path)
    }

    /// Cursor: `~/.cursor/mcp.json` (global MCP; rules live in Cursor's own UI).
    static func connectCursor(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        try connectMCPOnly(agent: "Cursor", configDir: ".cursor", fileName: "mcp.json",
                           home: home, mcpBinaryPath: mcpBinaryPath)
    }

    /// Windsurf: `~/.codeium/windsurf/mcp_config.json`.
    static func connectWindsurf(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        try connectMCPOnly(agent: "Windsurf", configDir: ".codeium/windsurf",
                           fileName: "mcp_config.json", home: home, mcpBinaryPath: mcpBinaryPath)
    }

    /// Agents whose entire wiring is one `mcpServers` JSON file — no global
    /// instruction file to install, because their rules live in the app's own UI.
    /// Only the directory, the filename, and the name differ.
    private static func connectMCPOnly(agent: String, configDir: String, fileName: String,
                                       home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        let dir = home.appendingPathComponent(configDir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let mcp = dir.appendingPathComponent(fileName)
        try mergeMCPJSON(at: mcp, mcpBinaryPath: mcpBinaryPath)

        return ConnectionResult(agent: agent, mcpConfigPath: mcp.path, instructionPath: nil)
    }

    // MARK: - Config writers

    /// Merge `mcpServers.contextos` into a JSON config, preserving everything
    /// else in the file. Creates the file (and parents) when absent.
    static func mergeMCPJSON(at url: URL, mcpBinaryPath: String) throws {
        let transaction = SettingsTransaction(home: url.deletingLastPathComponent())
        let name = url.lastPathComponent
        var editor = try JSONSettingsEditor(transaction.read(name), file: name)
        let path = ["mcpServers", "contextos"]
        if try editor.value(path) == nil { try editor.set(path, to: JSONSettingsEditor.encode([String: String]())) }
        try editor.set(path + ["command"], to: JSONSettingsEditor.encode(mcpBinaryPath))
        try editor.set(path + ["args"], to: JSONSettingsEditor.encode([String]()))
        try transaction.apply([transaction.change(name, after: editor.data)], agent: "MCP", action: "connect")
    }

    static let tomlBeginMarker = "# ContextOS:begin"
    static let tomlEndMarker = "# ContextOS:end"

    /// Insert (or replace) the `[mcp_servers.contextos]` block in a TOML config,
    /// bounded by comment markers so re-runs update in place.
    static func upsertTOMLBlock(at url: URL, mcpBinaryPath: String) throws {
        let transaction = SettingsTransaction(home: url.deletingLastPathComponent())
        let name = url.lastPathComponent
        var editor = try CodexSettingsEditor(transaction.read(name))
        if try editor.hasSection {
            try editor.set("command", to: String(data: JSONSettingsEditor.encode(mcpBinaryPath), encoding: .utf8)!)
            try editor.set("args", to: "[]")
        } else { try editor.addSection(command: mcpBinaryPath) }
        try transaction.apply([transaction.change(name, after: editor.data)], agent: "Codex", action: "connect")
    }
}
