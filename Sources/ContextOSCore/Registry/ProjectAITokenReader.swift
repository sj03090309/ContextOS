import Foundation

/// One AI agent's exact token total for a project.
public struct AgentTokens: Sendable, Identifiable {
    public var agent: String
    public var tokens: Int
    public init(agent: String, tokens: Int) { self.agent = agent; self.tokens = tokens }
    public var id: String { agent }
}

/// A project's token usage broken down by AI agent — the dashboard's per-project
/// card (like the reference: one project, a stacked bar, per-AI totals).
public struct ProjectAIUsage: Sendable, Identifiable {
    public var name: String                 // last path component, e.g. "pycoin"
    public var path: String                 // full project path
    public var total: Int                    // across all agents
    public var byAgent: [AgentTokens]        // tokens-desc, only agents with data

    public init(name: String, path: String, total: Int, byAgent: [AgentTokens]) {
        self.name = name
        self.path = path
        self.total = total
        self.byAgent = byAgent
    }

    public var id: String { path }
}

/// Combines each AI tool's **own exact token accounting** (not estimates) into a
/// per-project, per-agent breakdown. Only tools that record comparable local
/// token totals are included today: Claude Code and Codex.
public enum ProjectAITokenReader {

    public static func topProjects(limit: Int = 8) -> [ProjectAIUsage] {
        // Group by a canonical identity so the same project counts as one no matter
        // which path/cwd/symlink/clone reached it, and it shows under its current
        // on-disk name.
        var name: [String: String] = [:]
        var path: [String: String] = [:]
        var agentsByKey: [String: [String: Int]] = [:]
        func add(_ p: String, _ agent: String, _ tok: Int) {
            guard tok > 0 else { return }
            let id = canonicalProject(p)
            name[id.key] = id.name
            // Prefer an on-disk path for display; keep the first non-key path seen.
            if path[id.key] == nil || path[id.key] == id.key { path[id.key] = id.path }
            agentsByKey[id.key, default: [:]][agent, default: 0] += tok
        }

        for (p, tok) in ClaudeUsageReader.perProjectTotals() { add(p, "Claude Code", tok) }
        for (p, tok) in codexPerProject() { add(p, "Codex", tok) }

        let projects = agentsByKey.map { key, agents -> ProjectAIUsage in
            let list = agents
                .map { AgentTokens(agent: $0.key, tokens: $0.value) }
                .sorted { $0.tokens > $1.tokens }
            return ProjectAIUsage(name: name[key] ?? lastComponent(key), path: path[key] ?? key,
                                  total: list.reduce(0) { $0 + $1.tokens }, byAgent: list)
        }
        return projects.sorted { $0.total > $1.total }.prefix(limit).map { $0 }
    }

    public struct ProjectIdentity: Sendable { public var key: String; public var name: String; public var path: String }

    /// Resolve a project path to a stable identity that survives renames, moves,
    /// symlinks, and different working directories:
    /// 1. follow symlinks to the real path,
    /// 2. walk up to the enclosing git repo root,
    /// 3. key by the repo's normalized **remote URL** when present (so any local
    ///    copy of the same repo collapses to one), else by the real repo path.
    /// The display name/path always come from the current on-disk location.
    static func canonicalProject(_ input: String) -> ProjectIdentity {
        let fm = FileManager.default
        var resolved = input
        if fm.fileExists(atPath: input) {
            resolved = URL(fileURLWithPath: input).resolvingSymlinksInPath().path
        }
        // Walk up to the git repo root.
        var root: String?
        var dir = resolved
        while dir.count > 1 {
            if fm.fileExists(atPath: dir + "/.git") { root = dir; break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let displayPath = root ?? resolved
        if let root, let remote = gitRemote(atRepoRoot: root) {
            return ProjectIdentity(key: "git:" + remote, name: lastComponent(displayPath), path: displayPath)
        }
        return ProjectIdentity(key: displayPath, name: lastComponent(displayPath), path: displayPath)
    }

    /// Read the `origin` remote URL from `<root>/.git/config`, normalized so the
    /// SSH and HTTPS forms of the same repo match. No process spawned.
    private static func gitRemote(atRepoRoot root: String) -> String? {
        guard let text = try? String(contentsOfFile: root + "/.git/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "").lowercased() == "[remote\"origin\"]"
            } else if inOrigin, line.lowercased().hasPrefix("url") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                return normalizeRemote(String(line[line.index(after: eq)...]))
            }
        }
        return nil
    }

    private static func normalizeRemote(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespaces)
        for prefix in ["ssh://", "https://", "http://", "git://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if s.hasPrefix("git@") { s = String(s.dropFirst(4)) }
        s = s.replacingOccurrences(of: ":", with: "/")   // git@host:user/repo → host/user/repo
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
        return s.lowercased()
    }

    private static func lastComponent(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    // MARK: - Codex (~/.codex/sessions/**/rollout-*.jsonl)

    private static var codexSessionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    }

    /// Exact Codex tokens per project cwd, summed over sessions.
    private static func codexPerProject() -> [(path: String, tokens: Int)] {
        guard let en = FileManager.default.enumerator(
            at: codexSessionsDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }

        var totals: [String: Int] = [:]
        for case let url as URL in en where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let s = codexSession(for: url)
            if let cwd = s.cwd, s.tokens > 0 { totals[cwd, default: 0] += s.tokens }
        }
        return totals.map { ($0.key, $0.value) }
    }

    // Cache each rollout's (cwd, cumulative tokens) by mtime+size.
    private struct CodexCached { var mtime: TimeInterval; var size: Int; var cwd: String?; var tokens: Int }
    nonisolated(unsafe) private static var codexCache: [String: CodexCached] = [:]
    private static let codexLock = NSLock()

    private static func codexSession(for file: URL) -> (cwd: String?, tokens: Int) {
        let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = vals?.fileSize ?? 0
        let key = file.path

        codexLock.lock(); let hit = codexCache[key]; codexLock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size { return (hit.cwd, hit.tokens) }

        var cwd: String?
        var lastTotal = 0   // total_token_usage is cumulative; keep the last one
        if let raw = try? String(contentsOf: file, encoding: .utf8) {
            raw.enumerateLines { line, stop in
                guard line.contains("\"cwd\"") || line.contains("token_count") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                switch obj["type"] as? String {
                case "session_meta":
                    cwd = (obj["payload"] as? [String: Any])?["cwd"] as? String
                case "event_msg":
                    let payload = obj["payload"] as? [String: Any]
                    if payload?["type"] as? String == "token_count",
                       let info = payload?["info"] as? [String: Any],
                       let usage = info["total_token_usage"] as? [String: Any],
                       let total = usage["total_tokens"] as? Int {
                        lastTotal = total
                    }
                default:
                    break
                }
            }
        }

        codexLock.lock(); codexCache[key] = CodexCached(mtime: mtime, size: size, cwd: cwd, tokens: lastTotal); codexLock.unlock()
        return (cwd, lastTotal)
    }
}
