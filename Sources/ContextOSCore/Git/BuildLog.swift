import Foundation

/// One commit, with the code it moved and the AI agents credited for it.
public struct BuildCommit: Sendable, Identifiable {
    public var hash: String
    public var subject: String
    public var timestamp: Double
    /// Repo root this commit belongs to.
    public var project: String
    public var projectName: String
    public var added: Int
    public var deleted: Int
    /// Files touched, after noise filtering.
    public var files: Int
    /// AI agents credited — by a `Co-Authored-By` trailer, or by an agent
    /// session that was live in this project when the commit was made.
    public var agents: [String]

    public var id: String { project + ":" + hash }
    public var isAIAssisted: Bool { !agents.isEmpty }

    public init(hash: String, subject: String, timestamp: Double, project: String,
                projectName: String, added: Int, deleted: Int, files: Int, agents: [String]) {
        self.hash = hash
        self.subject = subject
        self.timestamp = timestamp
        self.project = project
        self.projectName = projectName
        self.added = added
        self.deleted = deleted
        self.files = files
        self.agents = agents
    }
}

/// A day's work: what was committed, what is still uncommitted, what it cost.
public struct BuildDay: Sendable, Identifiable {
    public var day: String              // local yyyy-MM-dd
    public var commits: [BuildCommit]   // newest first
    public var added = 0
    public var deleted = 0
    public var files = 0
    /// AI tokens spent across every project on this day.
    public var tokens = 0
    /// Work in the working tree that has not been committed. Only ever set for
    /// today — there is no way to know when older uncommitted edits were made.
    public var uncommittedAdded = 0
    public var uncommittedDeleted = 0

    public var id: String { day }
    public var isEmpty: Bool {
        commits.isEmpty && uncommittedAdded == 0 && uncommittedDeleted == 0 && tokens == 0
    }

    public init(day: String, commits: [BuildCommit] = []) {
        self.day = day
        self.commits = commits
    }
}

/// Headline figures for a period.
public struct BuildSummary: Sendable, Equatable {
    public var added = 0
    public var deleted = 0
    public var commits = 0
    public var tokens = 0
    /// Commits an AI was involved in — the share `git log` alone can't tell you.
    public var aiCommits = 0
    /// Days with anything on them: a commit, uncommitted work, or tokens spent.
    public var activeDays = 0

    public init() {}
}

/// A development journal assembled from Git history.
public struct BuildLog: Sendable {
    /// Days with something in them, newest first.
    public var days: [BuildDay] = []
    public var summary = BuildSummary()

    public init() {}
}

/// Builds the development journal.
///
/// ## Why this reads Git and not an agent's logs
/// Every coding agent — Claude Code, Codex, Cursor, Gemini CLI — writes its work
/// to the same place: the repository. So the journal is agent-agnostic by
/// construction, and works even for the parts you typed yourself. What the agent
/// transcripts add is *attribution and cost*: which commits an AI was involved
/// in, and how many tokens the day took. That join is the thing `git log` can't
/// do on its own.
///
/// ## What it does not do
/// It does not classify commits as "features" or "bug fixes", and it does not
/// summarize diffs into prose. Both would require either conventional-commit
/// discipline the average repo doesn't have, or an LLM call ContextOS won't
/// make. Commit subjects are already a human-written summary; they are shown
/// as-is rather than being paraphrased into something less accurate.
public enum BuildLogReader {

    /// Assemble the log for everything after `since`.
    ///
    /// - Parameters:
    ///   - since: epoch seconds; commits older than this are ignored.
    ///   - snapshot: AI usage, for per-day tokens and commit attribution.
    ///   - repos: repo roots to scan. Defaults to every project with local AI history.
    public static func log(since: Double,
                           snapshot: AgentUsageSnapshot? = nil,
                           repos: [String]? = nil) -> BuildLog {
        let usage = snapshot ?? AgentSessionReader.snapshot()
        let roots = repos ?? repositories(in: usage)
        let today = TimeKeys.localDay(Date().timeIntervalSince1970)

        var byDay: [String: BuildDay] = [:]
        var summary = BuildSummary()

        for root in roots {
            let url = URL(fileURLWithPath: root)
            let commits = self.commits(in: url, since: since, usage: usage)
            for commit in commits {
                let day = TimeKeys.localDay(commit.timestamp)
                var entry = byDay[day] ?? BuildDay(day: day)
                entry.commits.append(commit)
                entry.added += commit.added
                entry.deleted += commit.deleted
                entry.files += commit.files
                byDay[day] = entry

                summary.added += commit.added
                summary.deleted += commit.deleted
                summary.commits += 1
                if commit.isAIAssisted { summary.aiCommits += 1 }
            }

            // Work in progress: only meaningful for today, and only if the
            // period actually reaches today.
            if since <= Date().timeIntervalSince1970,
               let pending = uncommitted(in: url), pending.added + pending.deleted > 0 {
                var entry = byDay[today] ?? BuildDay(day: today)
                entry.uncommittedAdded += pending.added
                entry.uncommittedDeleted += pending.deleted
                byDay[today] = entry
            }
        }

        // Tokens are recorded per day across all projects, independent of commits —
        // a day of pure exploration has tokens and no commits, and should still
        // appear in the journal.
        for (day, tokens) in usage.byDay where dayStart(day) >= TimeKeys.localStartOfDay(since) {
            var entry = byDay[day] ?? BuildDay(day: day)
            entry.tokens = tokens
            byDay[day] = entry
            summary.tokens += tokens
        }

        var log = BuildLog()
        log.days = byDay.values
            .filter { !$0.isEmpty }
            .sorted { $0.day > $1.day }
            .map { day in
                var d = day
                d.commits.sort { $0.timestamp > $1.timestamp }
                return d
            }
        summary.activeDays = log.days.count
        log.summary = summary
        return log
    }

    /// Repo roots for every project with local AI history, de-duplicated by
    /// canonical identity so two checkouts of one repo don't double-count.
    public static func repositories(in usage: AgentUsageSnapshot) -> [String] {
        var seen: Set<String> = []
        var roots: [String] = []
        for project in usage.byProjectAgent.keys {
            let id = ProjectAITokenReader.canonicalProject(project)
            guard !seen.contains(id.key) else { continue }
            guard FileManager.default.fileExists(atPath: id.path + "/.git") else { continue }
            seen.insert(id.key)
            roots.append(id.path)
        }
        return roots.sorted()
    }

    /// Local midnight that starts a `yyyy-MM-dd` key.
    public static func dayStart(_ day: String) -> Double {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return 0 }
        // Midnight UTC for the civil date is close enough to order day keys
        // against a local-midnight bound; both sides use the same day string.
        return Double(TimeKeys.daysFromCivil(year: y, month: m, day: d)) * 86_400
            - Double(TimeZone.current.secondsFromGMT())
    }

    // MARK: - git log

    // Field/record separators that cannot occur in commit text.
    private static let unit = "\u{1f}"
    private static let record = "\u{1e}"

    private struct Memo { var head: String; var since: Double; var commits: [BuildCommit] }
    nonisolated(unsafe) private static var memo: [String: Memo] = [:]
    private static let memoLock = NSLock()

    /// Commits in one repo since `since`, with noise-filtered line counts.
    /// Memoized on the repo's HEAD — history is immutable, so the walk only
    /// re-runs when something is actually committed.
    static func commits(in root: URL, since: Double, usage: AgentUsageSnapshot) -> [BuildCommit] {
        let head = GitRunner.run(["rev-parse", "HEAD"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !head.isEmpty else { return [] }        // not a repo, or no commits yet

        memoLock.lock()
        let hit = memo[root.path]
        memoLock.unlock()
        if let hit, hit.head == head, hit.since <= since {
            return hit.commits.filter { $0.timestamp >= since }
        }

        let format = record + ["%H", "%ct", "%s", "%b"].joined(separator: unit) + unit
        guard let out = GitRunner.run([
            "log",
            "--since=\(Int(since))",
            "--no-merges",              // a merge's diff is its branch's, already counted
            "--numstat",
            "--pretty=format:\(format)"
        ], in: root) else { return [] }

        let name = ProjectAITokenReader.lastComponent(root.path)
        let parsed = out.components(separatedBy: record).compactMap {
            parse($0, project: root.path, projectName: name, usage: usage)
        }

        memoLock.lock()
        memo[root.path] = Memo(head: head, since: since, commits: parsed)
        memoLock.unlock()
        return parsed
    }

    /// Parse one `\x1e`-delimited record: metadata fields, then numstat lines.
    static func parse(_ chunk: String, project: String, projectName: String,
                      usage: AgentUsageSnapshot) -> BuildCommit? {
        guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fields = chunk.components(separatedBy: unit)
        guard fields.count >= 5,
              let seconds = Double(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }

        let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = fields[2]
        let body = fields[3]
        let stats = numstat(fields[4])

        return BuildCommit(
            hash: String(hash.prefix(7)), subject: subject, timestamp: seconds,
            project: project, projectName: projectName,
            added: stats.added, deleted: stats.deleted, files: stats.files,
            agents: attribute(body: body, at: seconds, project: project, usage: usage))
    }

    /// Sum `--numstat` lines, skipping paths that aren't the developer's work.
    static func numstat(_ text: String) -> (added: Int, deleted: Int, files: Int) {
        var added = 0, deleted = 0, files = 0
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let path = renameTarget(String(cols[2]))
            guard !isNoise(path) else { continue }
            // Binary files report "-" — real changes, but with no lines to count.
            guard let a = Int(cols[0]), let d = Int(cols[1]) else { continue }
            added += a
            deleted += d
            files += 1
        }
        return (added, deleted, files)
    }

    /// `--numstat` writes renames as `old => new` or `dir/{a => b}/file`.
    /// Only the destination matters for filtering.
    static func renameTarget(_ path: String) -> String {
        guard path.contains(" => ") else { return path }
        if let open = path.firstIndex(of: "{"), let close = path.firstIndex(of: "}"),
           open < close {
            let inner = path[path.index(after: open)..<close]
            let replacement = inner.components(separatedBy: " => ").last ?? ""
            let rebuilt = path[path.startIndex..<open] + replacement + path[path.index(after: close)...]
            return rebuilt.replacingOccurrences(of: "//", with: "/")
        }
        return path.components(separatedBy: " => ").last ?? path
    }

    // MARK: - Noise filtering

    /// Directories whose contents are fetched or generated, never authored.
    static let noiseDirectories = [
        "node_modules/", "vendor/", ".build/", "dist/", "build/", "out/",
        "Pods/", "Carthage/", ".venv/", "venv/", "target/", "__pycache__/",
        ".next/", ".nuxt/", "coverage/", "__snapshots__/", ".yarn/",
        ".gradle/", "DerivedData/", ".terraform/", "migrations/"
    ]

    /// Dependency lock files: enormous, machine-written, and not a day's work.
    static let noiseFilenames: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "npm-shrinkwrap.json",
        "Cargo.lock", "Gemfile.lock", "poetry.lock", "composer.lock", "go.sum",
        "Package.resolved", "Podfile.lock", "flake.lock", "bun.lockb", "mix.lock",
        "pubspec.lock", "uv.lock", "Pipfile.lock", "gradle.lockfile", "deno.lock"
    ]

    /// Generated, minified, or tool-owned files.
    static let noiseSuffixes = [
        ".min.js", ".min.css", ".map", ".lock", ".pbxproj", ".xcworkspacedata",
        ".pb.go", "_pb2.py", "_pb2_grpc.py", ".pb.cc", ".pb.h", ".pb.swift",
        ".g.dart", ".freezed.dart", ".generated.swift", ".designer.cs",
        ".snap", ".xcuserstate", ".pyc", ".class"
    ]

    /// Whether a path's line count would misrepresent the work done.
    ///
    /// This matters more than it looks: one refreshed `package-lock.json` is
    /// tens of thousands of lines and would swamp every real number in the log.
    public static func isNoise(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if noiseFilenames.contains(name) { return true }
        if noiseSuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        if path.hasPrefix(".contextos/") || path.contains("/.contextos/") { return true }
        // Anchor directory matches at a path boundary so a legitimately-named
        // file like "rebuild/foo.swift" isn't mistaken for "build/".
        let padded = "/" + path
        return noiseDirectories.contains { padded.contains("/" + $0) }
    }

    // MARK: - AI attribution

    /// Which agents to credit for a commit.
    ///
    /// Two signals, in order of confidence:
    /// 1. A `Co-Authored-By` trailer naming the agent — explicit and exact.
    /// 2. An agent session that was live in this project when the commit landed.
    ///    Circumstantial, but it is what lets Codex/Cursor/Gemini work show up
    ///    at all, since they add no trailer.
    static func attribute(body: String, at timestamp: Double, project: String,
                          usage: AgentUsageSnapshot) -> [String] {
        var agents: Set<String> = []

        let lowered = body.lowercased()
        if lowered.contains("co-authored-by:") {
            for line in lowered.split(separator: "\n") where line.contains("co-authored-by:") {
                if line.contains("claude") { agents.insert("Claude Code") }
                if line.contains("codex") || line.contains("openai") { agents.insert("Codex") }
                if line.contains("cursor") { agents.insert("Cursor") }
                if line.contains("gemini") { agents.insert("Gemini") }
                if line.contains("copilot") { agents.insert("Copilot") }
            }
        }

        let identity = ProjectAITokenReader.canonicalProject(project).key
        for session in usage.sessions where session.covers(timestamp) {
            guard ProjectAITokenReader.canonicalProject(session.project).key == identity else { continue }
            agents.insert(session.agent)
        }
        return agents.sorted()
    }

    // MARK: - Working tree

    /// Lines changed but not yet committed, noise-filtered. Nil outside a repo.
    static func uncommitted(in root: URL) -> (added: Int, deleted: Int)? {
        guard let out = GitRunner.run(["diff", "--numstat", "HEAD"], in: root) else { return nil }
        let stats = numstat(out)
        return (stats.added, stats.deleted)
    }

    /// Forget memoized history (tests, or a forced refresh).
    public static func invalidate() {
        memoLock.lock()
        memo.removeAll()
        memoLock.unlock()
    }
}
