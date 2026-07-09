import Foundation

/// Real AI token usage for a project, read from Claude Code's local session logs.
public struct ClaudeProjectUsage: Sendable {
    public var projectPath: String
    public var sessions: Int
    public var inputTokens: Int   // includes cache read/creation input
    public var outputTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens }
}

/// Reads token usage from `~/.claude/projects/<encoded>/*.jsonl`.
///
/// Purely local: it parses the user's own Claude Code transcripts on disk to sum
/// per-project token usage. Nothing leaves the machine. Other agents don't expose
/// a comparable local format, so only Claude Code is read for now.
public enum ClaudeUsageReader {

    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Claude Code encodes a project's absolute path by replacing "/" with "-".
    public static func encode(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }

    /// Token usage for one project, or nil if it has no Claude Code history.
    public static func usage(forProjectPath path: String) -> ClaudeProjectUsage? {
        let dir = projectsDir.appendingPathComponent(encode(path))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let sessions = files.filter { $0.pathExtension == "jsonl" }
        guard !sessions.isEmpty else { return nil }

        var input = 0, output = 0
        for file in sessions {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            content.enumerateLines { line, _ in
                // Cheap pre-filter before JSON parsing.
                guard line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    ?? obj["usage"] as? [String: Any]
                guard let u = usage else { return }
                input += intVal(u, "input_tokens") + intVal(u, "cache_read_input_tokens") + intVal(u, "cache_creation_input_tokens")
                output += intVal(u, "output_tokens")
            }
        }
        return ClaudeProjectUsage(projectPath: path, sessions: sessions.count, inputTokens: input, outputTokens: output)
    }

    private static func intVal(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }
}
