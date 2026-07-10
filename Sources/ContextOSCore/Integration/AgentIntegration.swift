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

    // MARK: - Per-agent wiring

    /// Codex CLI: `~/.codex/config.toml` ([mcp_servers.contextos]) + `~/.codex/AGENTS.md`.
    static func connectCodex(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        let dir = home.appendingPathComponent(".codex")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let toml = dir.appendingPathComponent("config.toml")
        try upsertTOMLBlock(at: toml, mcpBinaryPath: mcpBinaryPath)

        let agentsMD = dir.appendingPathComponent("AGENTS.md")
        try ClaudeIntegration.installInstruction(at: agentsMD)

        return ConnectionResult(agent: "Codex", mcpConfigPath: toml.path, instructionPath: agentsMD.path)
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
        let dir = home.appendingPathComponent(".cursor")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let mcp = dir.appendingPathComponent("mcp.json")
        try mergeMCPJSON(at: mcp, mcpBinaryPath: mcpBinaryPath)

        return ConnectionResult(agent: "Cursor", mcpConfigPath: mcp.path, instructionPath: nil)
    }

    /// Windsurf: `~/.codeium/windsurf/mcp_config.json`.
    static func connectWindsurf(home: URL, mcpBinaryPath: String) throws -> ConnectionResult? {
        let dir = home.appendingPathComponent(".codeium/windsurf")
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let mcp = dir.appendingPathComponent("mcp_config.json")
        try mergeMCPJSON(at: mcp, mcpBinaryPath: mcpBinaryPath)

        return ConnectionResult(agent: "Windsurf", mcpConfigPath: mcp.path, instructionPath: nil)
    }

    // MARK: - Config writers

    /// Merge `mcpServers.contextos` into a JSON config, preserving everything
    /// else in the file. Creates the file (and parents) when absent.
    static func mergeMCPJSON(at url: URL, mcpBinaryPath: String) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["contextos"] = ["command": mcpBinaryPath, "args": [String]()]
        root["mcpServers"] = servers

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    static let tomlBeginMarker = "# ContextOS:begin"
    static let tomlEndMarker = "# ContextOS:end"

    /// Insert (or replace) the `[mcp_servers.contextos]` block in a TOML config,
    /// bounded by comment markers so re-runs update in place.
    static func upsertTOMLBlock(at url: URL, mcpBinaryPath: String) throws {
        let block = """
        \(tomlBeginMarker)
        [mcp_servers.contextos]
        command = "\(mcpBinaryPath)"
        args = []
        \(tomlEndMarker)
        """

        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if let begin = content.range(of: tomlBeginMarker),
           let end = content.range(of: tomlEndMarker), end.upperBound >= begin.lowerBound {
            content.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            if !content.isEmpty { content += "\n" }
            content += block + "\n"
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
