import Foundation

/// One AI agent's exact token total for a project.
public struct AgentTokens: Sendable, Identifiable, Equatable {
    public var agent: String
    public var tokens: Int
    public init(agent: String, tokens: Int) { self.agent = agent; self.tokens = tokens }
    public var id: String { agent }
}

/// A project's token usage broken down by AI agent — the dashboard's per-project
/// card (one project, a stacked bar, per-AI totals).
public struct ProjectAIUsage: Sendable, Identifiable, Equatable {
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

/// Groups AI token usage by *project* rather than by session directory.
///
/// The numbers come from `AgentSessionReader`, which does the actual transcript
/// parsing. What this adds is **identity**: deciding that two paths are the same
/// project so their usage merges into one card.
public enum ProjectAITokenReader {

    /// Projects with the most AI token usage, merged by canonical identity.
    public static func topProjects(limit: Int = 8, snapshot: AgentUsageSnapshot? = nil) -> [ProjectAIUsage] {
        let usage = snapshot ?? AgentSessionReader.snapshot()

        var name: [String: String] = [:]
        var path: [String: String] = [:]
        var agentsByKey: [String: [String: Int]] = [:]

        for (project, agents) in usage.byProjectAgent {
            let id = canonicalProject(project)
            name[id.key] = id.name
            // Prefer a real on-disk path for display; keep the first one seen.
            if path[id.key] == nil || path[id.key] == id.key { path[id.key] = id.path }
            for (agent, tokens) in agents where tokens > 0 {
                agentsByKey[id.key, default: [:]][agent, default: 0] += tokens
            }
        }

        let projects = agentsByKey.compactMap { key, agents -> ProjectAIUsage? in
            let list = agents
                .map { AgentTokens(agent: $0.key, tokens: $0.value) }
                .sorted { $0.tokens > $1.tokens }
            let total = list.reduce(0) { $0 + $1.tokens }
            guard total > 0 else { return nil }
            return ProjectAIUsage(name: name[key] ?? lastComponent(key), path: path[key] ?? key,
                                  total: total, byAgent: list)
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
    public static func canonicalProject(_ input: String) -> ProjectIdentity {
        canonicalLock.lock()
        let hit = canonicalCache[input]
        canonicalLock.unlock()
        if let hit { return hit }

        let identity = computeCanonicalProject(input)
        canonicalLock.lock()
        canonicalCache[input] = identity
        canonicalLock.unlock()
        return identity
    }

    // Resolving an identity stats the filesystem and reads a git config; the set
    // of project paths is tiny and effectively fixed, so memoize it.
    nonisolated(unsafe) private static var canonicalCache: [String: ProjectIdentity] = [:]
    private static let canonicalLock = NSLock()

    /// Drop memoized identities (a repo may have gained a remote, or moved).
    public static func invalidate() {
        canonicalLock.lock()
        canonicalCache.removeAll()
        canonicalLock.unlock()
    }

    private static func computeCanonicalProject(_ input: String) -> ProjectIdentity {
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

    static func normalizeRemote(_ url: String) -> String {
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

    static func lastComponent(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}
