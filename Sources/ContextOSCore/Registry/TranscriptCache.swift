import Foundation

/// The transcript parse cache: every session log's parse, kept in memory for the
/// life of the process and written through to `UsageStore` so the next launch
/// starts warm.
///
/// The table is only ever this process's own derived data, so there is no point
/// reading it back on every refresh: that meant opening the database and
/// JSON-decoding every row twice per pass (once to use it, once more to prune
/// it). It is read once, and the database is only opened again when a row has
/// actually changed.
final class TranscriptCache: @unchecked Sendable {

    static let shared = TranscriptCache(storePath: UsageStore.defaultURL().path)

    private let storePath: String
    /// Nil until the first pass loads the persisted table.
    private var rows: [String: SessionCacheRow]?
    /// One pass at a time: two overlapping refreshes would parse the same bytes
    /// twice and race to write the same rows.
    private let lock = NSLock()

    init(storePath: String) {
        self.storePath = storePath
    }

    /// The working directory a transcript last recorded, if parsed. Returns nil
    /// rather than waiting while a pass holds the lock — the caller is the UI.
    func lastProject(forPath path: String) -> String? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard let project = rows?[path]?.lastProject, !project.isEmpty else { return nil }
        return project
    }

    /// Bring every transcript's parse up to date and fold them into a snapshot.
    func snapshot(of files: [(url: URL, agent: String)]) -> AgentUsageSnapshot {
        lock.lock()
        defer { lock.unlock() }

        var store: UsageStore?
        func openStore() -> UsageStore? {
            if store == nil { store = try? UsageStore(path: storePath) }
            return store
        }

        let cache = rows ?? openStore()?.sessionCache() ?? [:]
        var fresh: [String: SessionCacheRow] = [:]
        var changed: [SessionCacheRow] = []
        var live: Set<String> = []
        var snapshot = AgentUsageSnapshot()

        for file in files {
            let path = file.url.path
            snapshot.availableAgents.insert(file.agent)
            live.insert(path)
            let cached = cache[path]
            guard let row = AgentSessionReader.row(for: file.url, agent: file.agent, cached: cached)
            else { continue }
            fresh[path] = row

            // Write back whenever the file's identity moved — its mtime as well
            // as its size. A transcript that is touched without growing gets
            // re-parsed in full, and when only a size change counted as news its
            // new mtime was never saved: the cache kept describing the old file,
            // so the same full parse ran again on every refresh. Sixteen touched
            // logs made that 266MB of JSON every 32 seconds — a whole core for
            // six seconds out of every thirty-two, for as long as the app ran.
            if cached?.size != row.size || cached?.mtime != row.mtime {
                changed.append(row)
            }

            // One transcript can span several directories, so each is folded in
            // separately rather than the whole session landing on one project.
            for (project, usage) in row.projects where usage.tokens > 0 {
                snapshot.totalTokens += usage.tokens
                snapshot.byAgent[row.agent, default: 0] += usage.tokens
                snapshot.byProjectAgent[project, default: [:]][row.agent, default: 0] += usage.tokens
                for (day, tokens) in usage.days {
                    snapshot.byDay[day, default: 0] += tokens
                    snapshot.byAgentDay[row.agent, default: [:]][day, default: 0] += tokens
                }
                snapshot.sessions.append(AgentSession(
                    agent: row.agent, project: project,
                    start: usage.start == .greatestFiniteMagnitude ? usage.end : usage.start,
                    end: usage.end, tokens: usage.tokens))
            }
        }

        // Rows for transcripts that no longer exist, so the table can't grow
        // forever as sessions are deleted or rotated away.
        let gone = cache.keys.filter { !live.contains($0) }
        if !changed.isEmpty || !gone.isEmpty, let db = openStore() {
            try? db.upsertSessionCache(changed)
            db.deleteSessionCache(paths: gone)
        }
        rows = fresh
        return snapshot
    }
}
