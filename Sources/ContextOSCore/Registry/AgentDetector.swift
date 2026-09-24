import Foundation

/// A locally-detected AI coding agent.
public struct DetectedAgent: Sendable, Identifiable, Equatable {
    public var name: String
    public var present: Bool
    /// Installation evidence, such as Claude Code's project count. May be nil.
    public var detail: String?
    /// Whether this installed agent's own configuration explicitly registers
    /// ContextOS. Presence of an app/config directory alone is never enough.
    public var connection: ContextOSConnectionStatus
    /// What this computer can read from the agent's durable local records.
    /// A missing local record is deliberately not displayed as zero tokens.
    public var usage: LocalUsageStatus
    public var id: String { name }

    public init(name: String, present: Bool, detail: String? = nil,
                connection: ContextOSConnectionStatus = .unsupported,
                usage: LocalUsageStatus = .unavailable) {
        self.name = name
        self.present = present
        self.detail = detail
        self.connection = connection
        self.usage = usage
    }
}

/// The evidence for an installed agent's ContextOS connection.
public enum ContextOSConnectionStatus: Sendable, Equatable {
    /// The agent's configuration has a `contextos` MCP entry.
    case configured(path: String)
    /// ContextOS supports this agent, but the local configuration has no entry.
    case notConfigured(path: String)
    /// ContextOS has no configuration adapter for this agent.
    case unsupported

    public var summary: String {
        switch self {
        case .configured: return "MCP 설정됨"
        case .notConfigured: return "MCP 미설정"
        case .unsupported: return "ContextOS 연동 미지원"
        }
    }

    public var configPath: String? {
        switch self {
        case .configured(let path), .notConfigured(let path): return path
        case .unsupported: return nil
        }
    }

    public var isConfigured: Bool {
        if case .configured = self { return true }
        return false
    }
}

/// Whether a local, agent-authored token total is available to display.
public enum LocalUsageStatus: Sendable, Equatable {
    /// The token total is reconstructed from this agent's own local transcript.
    case reported(tokens: Int)
    /// The agent is supported, but no local token record exists yet.
    case noLocalRecord
    /// This agent does not persist a stable local token total ContextOS can read.
    case unavailable

    public var summary: String {
        switch self {
        case .reported(let tokens): return "로컬 기록 \(TokenEstimator.korean(tokens)) 토큰"
        case .noLocalRecord: return "로컬 사용 기록 없음"
        case .unavailable: return "로컬 토큰 기록 미제공"
        }
    }
}

/// Detects installed AI coding agents and verifies ContextOS connection from
/// their local configuration. It never infers a connection from a folder name.
public enum AgentDetector {
    private static func exists(_ relativePath: String, home: URL) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    private static func countEntries(_ relativePath: String, home: URL) -> Int? {
        let url = home.appendingPathComponent(relativePath)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return items.count
    }

    public static func detect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        usage: AgentUsageSnapshot? = nil
    ) -> [DetectedAgent] {
        var agents: [DetectedAgent] = []

        if exists(".claude", home: home) {
            let projects = countEntries(".claude/projects", home: home)
            let config = home.appendingPathComponent(".claude.json")
            agents.append(DetectedAgent(
                name: "Claude Code", present: true,
                detail: projects.map { "프로젝트 \($0)개" },
                connection: mcpStatus(in: config),
                usage: transcriptUsage(agent: "Claude Code", snapshot: usage)
            ))
        }

        let checks: [(String, [String], ContextOSConnectionStatus, LocalUsageStatus)] = [
            ("Codex", [".codex"], tomlStatus(in: home.appendingPathComponent(".codex/config.toml")),
             transcriptUsage(agent: "Codex", snapshot: usage)),
            ("Gemini CLI", [".gemini", ".config/gemini"],
             mcpStatus(in: home.appendingPathComponent(".gemini/settings.json")), .unavailable),
            ("Cursor", ["Library/Application Support/Cursor", ".cursor"],
             mcpStatus(in: home.appendingPathComponent(".cursor/mcp.json")), .unavailable),
            ("Windsurf", ["Library/Application Support/Windsurf", ".codeium"],
             mcpStatus(in: home.appendingPathComponent(".codeium/windsurf/mcp_config.json")), .unavailable),
            ("GitHub Copilot", [".config/github-copilot"], .unsupported, .unavailable),
            ("Continue", [".continue"], .unsupported, .unavailable),
            ("Aider", [".aider.conf.yml"], .unsupported, .unavailable),
            ("AgentCat", [".agentcat"], .unsupported, .unavailable)
        ]
        for (name, paths, connection, agentUsage) in checks
        where paths.contains(where: { exists($0, home: home) }) {
            agents.append(DetectedAgent(name: name, present: true, connection: connection, usage: agentUsage))
        }

        return agents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func transcriptUsage(agent: String, snapshot: AgentUsageSnapshot?) -> LocalUsageStatus {
        guard let snapshot else { return .noLocalRecord }
        guard snapshot.availableAgents.contains(agent) else { return .noLocalRecord }
        return .reported(tokens: snapshot.byAgent[agent, default: 0])
    }

    private static func mcpStatus(in url: URL) -> ContextOSConnectionStatus {
        let path = url.path
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              servers["contextos"] != nil
        else { return .notConfigured(path: path) }
        return .configured(path: path)
    }

    private static func tomlStatus(in url: URL) -> ContextOSConnectionStatus {
        let path = url.path
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              content.range(of: #"(?m)^\s*\[mcp_servers\.contextos\]\s*$"#,
                            options: .regularExpression) != nil
        else { return .notConfigured(path: path) }
        return .configured(path: path)
    }
}
