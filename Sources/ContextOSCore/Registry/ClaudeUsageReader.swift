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
        return usage(inDir: dir, label: path)
    }

    /// Exact total Claude tokens per project, keyed by the project's real path.
    public static func perProjectTotals() -> [(path: String, tokens: Int)] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir in
            guard let u = usage(inDir: dir, label: dir.lastPathComponent) else { return nil }
            return (decodePath(dir.lastPathComponent), u.totalTokens)
        }
    }

    /// Reverse of `encode`: turn a project directory name back into a path
    /// (best-effort; folder names containing "-" can't be told apart).
    public static func decodePath(_ dirName: String) -> String {
        dirName.hasPrefix("-")
            ? "/" + dirName.dropFirst().replacingOccurrences(of: "-", with: "/")
            : dirName.replacingOccurrences(of: "-", with: "/")
    }

    /// Total Claude Code token usage across **all** projects on this machine —
    /// for the dashboard's "AI 토큰 사용량" figure.
    public static func totalUsageAllProjects() -> (tokens: Int, projects: Int) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return (0, 0) }
        var total = 0, count = 0
        for dir in dirs {
            if let u = usage(inDir: dir, label: dir.lastPathComponent) {
                total += u.totalTokens; count += 1
            }
        }
        return (total, count)
    }

    private static func usage(inDir dir: URL, label: String) -> ClaudeProjectUsage? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        let sessions = files.filter { $0.pathExtension == "jsonl" }
        guard !sessions.isEmpty else { return nil }

        var input = 0, output = 0
        for file in sessions {
            let t = tokens(for: file)
            input += t.input; output += t.output
        }
        return ClaudeProjectUsage(projectPath: label, sessions: sessions.count, inputTokens: input, outputTokens: output)
    }

    // MARK: - Per-file cache

    // Session transcripts are large and mostly append-only; re-parsing every one
    // on each dashboard refresh is expensive. Cache per file, keyed by mtime+size,
    // so only files that actually changed are re-parsed.
    private struct Cached { var mtime: TimeInterval; var size: Int; var input: Int; var output: Int }
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let cacheLock = NSLock()

    private static func tokens(for file: URL) -> (input: Int, output: Int) {
        let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = vals?.fileSize ?? 0
        let key = file.path

        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size {
            return (hit.input, hit.output)
        }

        var input = 0, output = 0
        if let content = try? String(contentsOf: file, encoding: .utf8) {
            content.enumerateLines { line, _ in
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

        cacheLock.lock()
        cache[key] = Cached(mtime: mtime, size: size, input: input, output: output)
        cacheLock.unlock()
        return (input, output)
    }

    private static func intVal(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }
}
