import Foundation

/// One AI coding session that ran against a project.
public struct AgentSession: Sendable {
    public var agent: String
    /// The session's working directory.
    public var project: String
    public var start: Double
    public var end: Double
    public var tokens: Int

    public init(agent: String, project: String, start: Double, end: Double, tokens: Int) {
        self.agent = agent
        self.project = project
        self.start = start
        self.end = end
        self.tokens = tokens
    }

    /// Whether an instant falls inside this session's wall-clock span.
    public func covers(_ timestamp: Double) -> Bool {
        timestamp >= start && timestamp <= end
    }
}

/// Everything the dashboard needs about local AI usage, from a single pass.
public struct AgentUsageSnapshot: Sendable {
    public var totalTokens = 0
    /// project cwd → agent → tokens.
    public var byProjectAgent: [String: [String: Int]] = [:]
    /// local `yyyy-MM-dd` → tokens, across every agent.
    public var byDay: [String: Int] = [:]
    public var sessions: [AgentSession] = []

    public init() {}
}

/// Reads every local AI coding agent's own token accounting in one pass.
///
/// ## What each agent exposes locally
/// - **Claude Code** — `~/.claude/projects/<encoded-cwd>/*.jsonl`. Every assistant
///   message carries an exact `usage` block and an ISO8601 `timestamp`, plus the
///   `cwd` it ran in. Complete: totals, per-project, per-day, session spans.
/// - **Codex** — `~/.codex/sessions/**/rollout-*.jsonl`. `session_meta` gives the
///   `cwd`; `token_count` events give a **cumulative** `total_token_usage`.
///   Per-day totals come from differencing consecutive cumulative values (summing
///   the reported per-turn `last_token_usage` instead drifts ~1% high).
/// - **Gemini CLI** — writes chat logs under `~/.gemini`, but no token accounting;
///   its usage telemetry is opt-in OTLP that goes to a collector, not to disk.
/// - **Cursor** — chat lives in a private, version-unstable `state.vscdb`, and
///   token accounting is server-side (subscription usage), never local.
///
/// So only Claude Code and Codex can be reported as exact token figures. The
/// other two are still detected (see `AgentDetector`) and still get ContextOS
/// wired into them (see `AgentIntegration`) — we just don't invent numbers for
/// them. Build Log itself is agent-agnostic: it reads Git, which every agent
/// writes to identically.
///
/// Purely local: the user's own files on their own disk. Nothing leaves the machine.
public enum AgentSessionReader {

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeProjectsDir: URL { home.appendingPathComponent(".claude/projects") }
    static var codexSessionsDir: URL { home.appendingPathComponent(".codex/sessions") }

    // The snapshot is shared by several dashboard sections that refresh together;
    // recomputing it per section would walk the transcript tree N times.
    private struct Memo { var snapshot: AgentUsageSnapshot; var at: Double }
    nonisolated(unsafe) private static var memo: Memo?
    private static let memoLock = NSLock()

    /// Aggregate local AI usage. Results are memoized for `maxAge` seconds;
    /// pass `force: true` to rebuild now (the manual ↻ button).
    public static func snapshot(maxAge: Double = 25, force: Bool = false) -> AgentUsageSnapshot {
        let now = Date().timeIntervalSince1970
        if !force {
            memoLock.lock()
            let hit = memo
            memoLock.unlock()
            if let hit, now - hit.at < maxAge { return hit.snapshot }
        }
        let fresh = build()
        memoLock.lock()
        memo = Memo(snapshot: fresh, at: now)
        memoLock.unlock()
        return fresh
    }

    /// Forget the memoized snapshot (tests, or an explicit refresh).
    public static func invalidate() {
        memoLock.lock()
        memo = nil
        memoLock.unlock()
    }

    private static func build() -> AgentUsageSnapshot {
        let files = claudeTranscripts().map { (url: $0, agent: "Claude Code") }
            + codexTranscripts().map { (url: $0, agent: "Codex") }

        let store = try? UsageStore(path: UsageStore.defaultURL().path)
        let cache = store?.sessionCache() ?? [:]

        var rows: [SessionCacheRow] = []        // only the ones we (re)parsed
        var live: Set<String> = []
        var snapshot = AgentUsageSnapshot()

        for file in files {
            live.insert(file.url.path)
            guard let row = row(for: file.url, agent: file.agent, cached: cache[file.url.path])
            else { continue }
            if cache[file.url.path]?.size != row.size {
                rows.append(row)                // new, or grew on disk → write it back
            }

            // One transcript can span several directories, so each is folded in
            // separately rather than the whole session landing on one project.
            for (project, usage) in row.projects where usage.tokens > 0 {
                snapshot.totalTokens += usage.tokens
                snapshot.byProjectAgent[project, default: [:]][row.agent, default: 0] += usage.tokens
                for (day, tokens) in usage.days { snapshot.byDay[day, default: 0] += tokens }
                snapshot.sessions.append(AgentSession(
                    agent: row.agent, project: project,
                    start: usage.start == .greatestFiniteMagnitude ? usage.end : usage.start,
                    end: usage.end, tokens: usage.tokens))
            }
        }

        try? store?.upsertSessionCache(rows)
        store?.pruneSessionCache(keeping: live)
        return snapshot
    }

    // MARK: - Transcript discovery

    private static func claudeTranscripts() -> [URL] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs.flatMap { dir -> [URL] in
            (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
        }
    }

    private static func codexTranscripts() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: codexSessionsDir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
        }
    }

    // MARK: - Incremental parsing

    /// Return an up-to-date parse of one transcript, doing as little work as the
    /// file's state allows: nothing if it is unchanged, tail-only if it grew.
    static func row(for file: URL, agent: String, cached: SessionCacheRow?) -> SessionCacheRow? {
        // Deliberately not `URL.resourceValues`: NSURL memoizes those on the URL
        // instance, so asking the same URL twice returns the size and mtime from
        // the first ask and an append would never be noticed. FileManager stats
        // the file every time.
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        // Unchanged since the last read — reuse it verbatim.
        if let cached, cached.mtime == mtime, cached.size == size { return cached }

        // Grew and the prefix we already consumed is still there: parse only the
        // appended bytes and fold them into the cached totals. This is the common
        // case — the session the user is in right now appends on every turn, and
        // its transcript can be tens of megabytes.
        if let cached, size > cached.size {
            var row = cached
            row.mtime = mtime
            guard let consumed = accumulate(file, from: cached.size, agent: agent, into: &row)
            else { return cached }
            row.size = cached.size + consumed
            return row
        }

        // No cache, or the file shrank/was rewritten — parse it whole.
        var row = SessionCacheRow(path: file.path, agent: agent, mtime: mtime, size: 0)
        guard let consumed = accumulate(file, from: 0, agent: agent, into: &row) else { return nil }
        row.size = consumed
        return row
    }

    /// Stream `file` from `offset` and fold each line into `row`.
    ///
    /// Streaming rather than reading the file in: a 63MB transcript costs its
    /// size as `Data` and again as `String`, and a cold pass over every log
    /// peaked this app at ~295MB. Line by line it stays flat.
    ///
    /// - Returns: bytes of complete lines consumed, or nil if unreadable.
    private static func accumulate(_ file: URL, from offset: Int, agent: String,
                                   into row: inout SessionCacheRow) -> Int? {
        switch agent {
        case "Codex": return accumulateCodex(file, from: offset, into: &row)
        default: return accumulateClaude(file, from: offset, into: &row)
        }
    }

    // MARK: - Claude Code

    private static func accumulateClaude(_ file: URL, from offset: Int,
                                         into row: inout SessionCacheRow) -> Int? {
        var acc = row
        // A transcript is not pinned to one directory: the user can `cd`, or
        // resume the session elsewhere, and later lines carry a different cwd.
        // Attribute each message to the directory it was actually sent from.
        var cwd = row.lastProject.isEmpty
            ? decodeClaudeDir(URL(fileURLWithPath: row.path).deletingLastPathComponent().lastPathComponent)
            : row.lastProject

        let consumed = LineReader.forEachLine(of: file, from: offset) { line in
            // Cheap reject before paying for JSON parsing — most lines are user
            // turns, tool results, and metadata with no usage block.
            guard line.contains("\"usage\"") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            // The transcript records the cwd it ran in — more reliable than
            // decoding the directory name, which is lossy for any project whose
            // own name contains a "-".
            if let recorded = obj["cwd"] as? String, !recorded.isEmpty { cwd = recorded }

            guard let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
                    ?? obj["usage"] as? [String: Any] else { return }
            let tokens = int(usage, "input_tokens") + int(usage, "cache_read_input_tokens")
                + int(usage, "cache_creation_input_tokens") + int(usage, "output_tokens")
            guard tokens > 0 else { return }

            let stamp = obj["timestamp"] as? String
            acc.add(tokens: tokens, at: stamp.flatMap { TimeKeys.epoch(fromISO8601: $0) }, project: cwd)
        }
        acc.lastProject = cwd
        row = acc
        return consumed
    }

    /// Turn Claude Code's encoded project directory name (a path with "/"
    /// replaced by "-") back into a path. Best-effort and lossy — a directory
    /// whose own name contains "-" is indistinguishable from a path separator —
    /// which is why the `cwd` recorded inside the transcript is preferred, and
    /// this is only a fallback for transcripts that carry no cwd at all.
    public static func decodeClaudeDir(_ name: String) -> String {
        name.hasPrefix("-")
            ? "/" + name.dropFirst().replacingOccurrences(of: "-", with: "/")
            : name.replacingOccurrences(of: "-", with: "/")
    }

    // MARK: - Codex

    private static func accumulateCodex(_ file: URL, from offset: Int,
                                        into row: inout SessionCacheRow) -> Int? {
        var acc = row
        var previous = row.cursor          // last cumulative total we saw
        var cwd = row.lastProject          // set once, by session_meta

        let consumed = LineReader.forEachLine(of: file, from: offset) { line in
            guard line.contains("\"cwd\"") || line.contains("token_count") else { return }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { return }

            switch obj["type"] as? String {
            case "session_meta":
                if let recorded = payload["cwd"] as? String, !recorded.isEmpty { cwd = recorded }
            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["total_token_usage"] as? [String: Any],
                      let total = usage["total_tokens"] as? Int
                else { return }

                // `total_token_usage` is cumulative for the session, so the work
                // done since the last event is the difference. A decrease means
                // the counter restarted, in which case the new value is itself
                // the delta.
                let cumulative = Double(total)
                let delta = cumulative < previous ? cumulative : cumulative - previous
                previous = cumulative
                guard delta > 0 else { return }

                let stamp = obj["timestamp"] as? String
                acc.add(tokens: Int(delta),
                        at: stamp.flatMap { TimeKeys.epoch(fromISO8601: $0) },
                        project: cwd)
            default:
                return
            }
        }
        acc.cursor = previous
        acc.lastProject = cwd
        row = acc
        return consumed
    }

    private static func int(_ dict: [String: Any], _ key: String) -> Int {
        (dict[key] as? NSNumber)?.intValue ?? 0
    }
}
