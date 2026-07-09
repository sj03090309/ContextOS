import Foundation

/// A locally-detected AI coding agent.
public struct DetectedAgent: Sendable, Identifiable {
    public var name: String
    public var present: Bool
    /// Extra info we could read locally (e.g. Claude Code project count). May be nil.
    public var detail: String?
    public var id: String { name }
}

/// Detects which AI coding agents are installed/used on this machine by looking
/// for their local config/session directories.
///
/// This is pure local filesystem inspection — no API, no network. It reports
/// *presence*; it does not claim to read every agent's token usage (formats
/// differ per tool). For Claude Code it can read a bit more (project count).
public enum AgentDetector {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static func exists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    private static func countEntries(_ relativePath: String) -> Int? {
        let url = home.appendingPathComponent(relativePath)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        return items.count
    }

    public static func detect() -> [DetectedAgent] {
        var agents: [DetectedAgent] = []

        // Claude Code — richest local data.
        if exists(".claude") {
            let projects = countEntries(".claude/projects")
            agents.append(DetectedAgent(
                name: "Claude Code", present: true,
                detail: projects.map { "프로젝트 \($0)개" }
            ))
        }

        // Other agents: presence detection via known config dirs.
        let checks: [(String, [String])] = [
            ("Cursor", ["Library/Application Support/Cursor", ".cursor"]),
            ("GitHub Copilot", [".config/github-copilot"]),
            ("Codex", [".codex"]),
            ("Gemini", [".gemini", ".config/gemini"]),
            ("Windsurf", ["Library/Application Support/Windsurf", ".codeium"]),
            ("Continue", [".continue"]),
            ("Aider", [".aider.conf.yml"]),
            ("AgentCat", [".agentcat"])
        ]
        for (name, paths) in checks where paths.contains(where: exists) {
            agents.append(DetectedAgent(name: name, present: true, detail: nil))
        }

        return agents
    }
}
