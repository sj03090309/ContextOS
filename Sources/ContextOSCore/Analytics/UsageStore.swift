import Foundation
import SQLite3

/// A single "optimized a query" event.
public struct UsageEvent: Sendable, Equatable {
    public var timestamp: Double
    public var project: String
    public var query: String
    public var selectedTokens: Int
    public var fullTokens: Int
    public var contextScore: Int
    public var fileCount: Int

    public init(
        timestamp: Double = Date().timeIntervalSince1970,
        project: String,
        query: String,
        selectedTokens: Int,
        fullTokens: Int,
        contextScore: Int,
        fileCount: Int
    ) {
        self.timestamp = timestamp
        self.project = project
        self.query = query
        self.selectedTokens = selectedTokens
        self.fullTokens = fullTokens
        self.contextScore = contextScore
        self.fileCount = fileCount
    }

    public var savedTokens: Int { max(0, fullTokens - selectedTokens) }
}

/// Aggregated usage stats.
public struct UsageSummary: Sendable {
    public var queryCount: Int
    public var totalSaved: Int
    public var avgSelectedTokens: Int
    public var avgContextScore: Int
    public var perProject: [(project: String, saved: Int, count: Int)]

    public init(
        queryCount: Int, totalSaved: Int, avgSelectedTokens: Int,
        avgContextScore: Int, perProject: [(project: String, saved: Int, count: Int)]
    ) {
        self.queryCount = queryCount
        self.totalSaved = totalSaved
        self.avgSelectedTokens = avgSelectedTokens
        self.avgContextScore = avgContextScore
        self.perProject = perProject
    }
}

/// What one session spent inside one working directory.
///
/// A single transcript can span several directories — the user `cd`s, or resumes
/// a session somewhere else — so usage is bucketed per project rather than
/// pinned to whichever directory the session happened to end in.
public struct SessionProjectUsage: Sendable, Codable, Equatable {
    public var tokens: Int
    /// Wall-clock span of the work done here, used to attribute commits.
    public var start: Double
    public var end: Double
    /// Tokens bucketed by local `yyyy-MM-dd`.
    public var days: [String: Int]

    public init(tokens: Int = 0, start: Double = .greatestFiniteMagnitude,
                end: Double = 0, days: [String: Int] = [:]) {
        self.tokens = tokens
        self.start = start
        self.end = end
        self.days = days
    }

    // Short keys: this is serialized once per session file and never read by a
    // human, so the JSON stays small.
    enum CodingKeys: String, CodingKey {
        case tokens = "t", start = "s", end = "e", days = "d"
    }
}

/// One parsed AI session transcript, cached so it is only read once per change.
///
/// The transcripts are large and append-only; re-parsing every one on each
/// dashboard refresh (and again on every app launch) is the single most
/// expensive thing the app does. `mtime` + `size` identify a parse result.
public struct SessionCacheRow: Sendable {
    public var path: String
    public var agent: String
    public var mtime: Double
    /// Bytes consumed so far — the offset just past the last **complete** line.
    /// Transcripts are append-only, so the next refresh resumes from here and
    /// only parses what was appended. A partial trailing line is left unread
    /// until the writer finishes it.
    public var size: Int
    /// Parser state carried across incremental reads. Codex reports a
    /// *cumulative* total per event, so resuming needs the previous value to
    /// turn the next one back into a delta. Unused (0) for Claude, whose usage
    /// figures are already per-message.
    public var cursor: Double
    /// The last working directory seen, so a line that omits `cwd` still lands
    /// in the right bucket. Not itself a usage figure.
    public var lastProject: String
    /// Usage keyed by working directory.
    public var projects: [String: SessionProjectUsage]

    public init(path: String, agent: String, mtime: Double, size: Int,
                cursor: Double = 0, lastProject: String = "",
                projects: [String: SessionProjectUsage] = [:]) {
        self.path = path
        self.agent = agent
        self.mtime = mtime
        self.size = size
        self.cursor = cursor
        self.lastProject = lastProject
        self.projects = projects
    }

    public var tokens: Int { projects.values.reduce(0) { $0 + $1.tokens } }

    /// Fold `tokens` spent at `timestamp` in `project` into the row.
    mutating func add(tokens: Int, at timestamp: Double?, project: String) {
        guard tokens > 0, !project.isEmpty else { return }
        var bucket = projects[project] ?? SessionProjectUsage()
        bucket.tokens += tokens
        if let timestamp {
            bucket.start = min(bucket.start, timestamp)
            bucket.end = max(bucket.end, timestamp)
            bucket.days[TimeKeys.localDay(timestamp), default: 0] += tokens
        }
        projects[project] = bucket
    }
}

/// Local, cross-project analytics DB. Short-lived: open, use, discard.
///
/// Kept entirely separate from the per-project index so analytics survive
/// re-indexing and span every project on the machine. Also holds the parse
/// caches for AI session transcripts and Git history — derived data that is
/// expensive to rebuild and safe to throw away, so it lives here rather than in
/// a second database.
public final class UsageStore {

    private var db: OpaquePointer?
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `~/Library/Application Support/ContextOS/usage.sqlite`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ContextOS", isDirectory: true)
            .appendingPathComponent("usage.sqlite")
    }

    public init(path: String) throws {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw IndexStoreError.open(message)
        }
        // Every session's MCP server (plus the per-prompt hook, plus the menu-bar
        // app reading) writes/reads this one shared DB — wait for the lock rather
        // than failing instantly when they overlap.
        if path != ":memory:" {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA busy_timeout=5000;")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS usage (
            id         INTEGER PRIMARY KEY,
            ts         REAL NOT NULL,
            project    TEXT NOT NULL,
            query      TEXT NOT NULL,
            selected   INTEGER NOT NULL,
            full       INTEGER NOT NULL,
            score      INTEGER NOT NULL,
            files      INTEGER NOT NULL
        );
        """)
        // Day-bucketed queries scan by timestamp; without this every refresh is
        // a full table scan that grows for as long as the user keeps the app.
        try exec("CREATE INDEX IF NOT EXISTS usage_ts ON usage(ts);")
        try exec("""
        CREATE TABLE IF NOT EXISTS session_cache (
            path        TEXT PRIMARY KEY,
            agent       TEXT NOT NULL,
            mtime       REAL NOT NULL,
            size        INTEGER NOT NULL,
            cursor      REAL NOT NULL,
            lastProject TEXT NOT NULL,
            projects    TEXT NOT NULL
        );
        """)
        // One row per project/day/kind. Debt is only measurable against itself
        // over time, and nothing else records history, so it accumulates here.
        try exec("""
        CREATE TABLE IF NOT EXISTS debt_snapshot (
            project TEXT NOT NULL,
            day     TEXT NOT NULL,
            kind    TEXT NOT NULL,
            count   INTEGER NOT NULL,
            PRIMARY KEY (project, day, kind)
        );
        """)
    }

    deinit { sqlite3_close(db) }

    /// Posted (cross-process) right after an optimization is recorded, so a
    /// monitor like the menu-bar app can react in real time instead of polling.
    public static let optimizedNotification = Notification.Name("com.contextos.optimized")

    /// Posted (cross-process) when the MCP server handles a real **tool call** —
    /// a lightweight "an agent is working right now" heartbeat that keeps the
    /// mascot alive even for agents whose session logs we can't read.
    ///
    /// Deliberately not fired for every request: an idle MCP connection still
    /// exchanges `ping`, `initialize` and `tools/list`, so heart-beating on those
    /// made the mascot eat whenever a session was merely open. See
    /// `isAgentActivity`.
    public static let activityNotification = Notification.Name("com.contextos.activity")

    /// Whether a JSON-RPC method means the agent is actively working, rather than
    /// protocol housekeeping (handshake, capability listing, keepalive ping). Only
    /// a tool call is real work; the rest happens on an idle connection and must
    /// not wake the mascot.
    public static func isAgentActivity(method: String) -> Bool {
        method == "tools/call"
    }

    /// Posted the instant a turn *starts* (the UserPromptSubmit hook) and *ends*
    /// (the Stop hook), so the mascot can react in real time — eating the moment
    /// the user hits enter and stopping the moment the agent finishes.
    public static let turnStartNotification = Notification.Name("com.contextos.turnStart")
    public static let turnStopNotification = Notification.Name("com.contextos.turnStop")

    /// Convenience: open the default DB, record one event, close.
    public static func record(_ event: UsageEvent) {
        guard let store = try? UsageStore(path: defaultURL().path) else { return }
        guard (try? store.record(event)) != nil else { return }
        DistributedNotificationCenter.default().postNotificationName(
            optimizedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    public func record(_ event: UsageEvent) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        INSERT INTO usage (ts, project, query, selected, full, score, files)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """, -1, &stmt, nil) == SQLITE_OK else {
            throw IndexStoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, event.timestamp)
        bindText(stmt, 2, event.project)
        bindText(stmt, 3, event.query)
        sqlite3_bind_int64(stmt, 4, Int64(event.selectedTokens))
        sqlite3_bind_int64(stmt, 5, Int64(event.fullTokens))
        sqlite3_bind_int64(stmt, 6, Int64(event.contextScore))
        sqlite3_bind_int64(stmt, 7, Int64(event.fileCount))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw IndexStoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Tokens saved since local midnight.
    public func todaySaved() -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return scalar("SELECT COALESCE(SUM(MAX(full - selected, 0)), 0) FROM usage WHERE ts >= \(startOfDay);")
    }

    public func summary() -> UsageSummary {
        let count = scalar("SELECT COUNT(*) FROM usage;")
        let totalSaved = scalar("SELECT COALESCE(SUM(MAX(full - selected, 0)), 0) FROM usage;")
        let avgSelected = scalar("SELECT COALESCE(CAST(AVG(selected) AS INTEGER), 0) FROM usage;")
        let avgScore = scalar("SELECT COALESCE(CAST(AVG(score) AS INTEGER), 0) FROM usage;")

        var perProject: [(String, Int, Int)] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, """
        SELECT project, COALESCE(SUM(MAX(full - selected, 0)), 0) AS saved, COUNT(*) AS n
        FROM usage GROUP BY project ORDER BY saved DESC LIMIT 10;
        """, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let project = String(cString: sqlite3_column_text(stmt, 0))
                perProject.append((project, Int(sqlite3_column_int64(stmt, 1)), Int(sqlite3_column_int64(stmt, 2))))
            }
        }
        sqlite3_finalize(stmt)

        return UsageSummary(
            queryCount: count, totalSaved: totalSaved,
            avgSelectedTokens: avgSelected, avgContextScore: avgScore,
            perProject: perProject
        )
    }

    /// Most recent events, newest first.
    public func recentEvents(limit: Int = 8) -> [UsageEvent] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT ts, project, query, selected, full, score, files
        FROM usage ORDER BY ts DESC LIMIT \(limit);
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var events: [UsageEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            events.append(UsageEvent(
                timestamp: sqlite3_column_double(stmt, 0),
                project: String(cString: sqlite3_column_text(stmt, 1)),
                query: String(cString: sqlite3_column_text(stmt, 2)),
                selectedTokens: Int(sqlite3_column_int64(stmt, 3)),
                fullTokens: Int(sqlite3_column_int64(stmt, 4)),
                contextScore: Int(sqlite3_column_int64(stmt, 5)),
                fileCount: Int(sqlite3_column_int64(stmt, 6))
            ))
        }
        return events
    }

    // MARK: - Session transcript cache

    /// Every cached transcript parse, keyed by file path.
    public func sessionCache() -> [String: SessionCacheRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT path, agent, mtime, size, cursor, lastProject, projects FROM session_cache;
        """, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: SessionCacheRow] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
            out[path] = SessionCacheRow(
                path: path,
                agent: String(cString: sqlite3_column_text(stmt, 1)),
                mtime: sqlite3_column_double(stmt, 2),
                size: Int(sqlite3_column_int64(stmt, 3)),
                cursor: sqlite3_column_double(stmt, 4),
                lastProject: String(cString: sqlite3_column_text(stmt, 5)),
                projects: Self.decodeProjects(String(cString: sqlite3_column_text(stmt, 6))))
        }
        return out
    }

    /// Insert or refresh cached parses. Wrapped in one transaction — a session
    /// refresh can touch hundreds of rows and SQLite would otherwise fsync each.
    public func upsertSessionCache(_ rows: [SessionCacheRow]) throws {
        guard !rows.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            INSERT INTO session_cache (path, agent, mtime, size, cursor, lastProject, projects)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                agent=excluded.agent, mtime=excluded.mtime, size=excluded.size,
                cursor=excluded.cursor, lastProject=excluded.lastProject,
                projects=excluded.projects;
            """, -1, &stmt, nil) == SQLITE_OK else {
                throw IndexStoreError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for row in rows {
                sqlite3_reset(stmt)
                bindText(stmt, 1, row.path)
                bindText(stmt, 2, row.agent)
                sqlite3_bind_double(stmt, 3, row.mtime)
                sqlite3_bind_int64(stmt, 4, Int64(row.size))
                sqlite3_bind_double(stmt, 5, row.cursor)
                bindText(stmt, 6, row.lastProject)
                bindText(stmt, 7, Self.encodeProjects(row.projects))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw IndexStoreError.step(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Drop cache rows for transcripts that no longer exist on disk, so the
    /// table can't grow forever as sessions are deleted or rotated away.
    public func pruneSessionCache(keeping live: Set<String>) {
        let stale = sessionCache().keys.filter { !live.contains($0) }
        guard !stale.isEmpty else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM session_cache WHERE path = ?;",
                                 -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for path in stale {
            sqlite3_reset(stmt)
            bindText(stmt, 1, path)
            _ = sqlite3_step(stmt)
        }
    }

    /// A session's per-project usage is small (a handful of directories over a
    /// handful of days), so JSON in one column beats a second table and a join.
    static func encodeProjects(_ projects: [String: SessionProjectUsage]) -> String {
        guard !projects.isEmpty,
              let data = try? JSONEncoder().encode(projects),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func decodeProjects(_ text: String) -> [String: SessionProjectUsage] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: SessionProjectUsage].self, from: data)
        else { return [:] }
        return obj
    }

    // MARK: - Code debt history

    /// Record today's debt counts. Re-running the same day overwrites, so the
    /// snapshot is "where the project ended up on that day".
    public func recordDebtSnapshot(project: String, day: String, counts: [String: Int]) throws {
        guard !counts.isEmpty else { return }
        try exec("BEGIN IMMEDIATE;")
        do {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
            INSERT INTO debt_snapshot (project, day, kind, count) VALUES (?, ?, ?, ?)
            ON CONFLICT(project, day, kind) DO UPDATE SET count = excluded.count;
            """, -1, &stmt, nil) == SQLITE_OK else {
                throw IndexStoreError.prepare(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            for (kind, count) in counts {
                sqlite3_reset(stmt)
                bindText(stmt, 1, project)
                bindText(stmt, 2, day)
                bindText(stmt, 3, kind)
                sqlite3_bind_int64(stmt, 4, Int64(count))
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw IndexStoreError.step(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Counts from the oldest snapshot within `days` before `since`, for a
    /// baseline to compare today against. Empty when nothing was recorded yet.
    public func oldestDebtSnapshot(project: String, since day: String, days: Int) -> [String: Int] {
        var stmt: OpaquePointer?
        // Day keys are zero-padded, so lexical ordering is chronological.
        guard sqlite3_prepare_v2(db, """
        SELECT kind, count FROM debt_snapshot
        WHERE project = ? AND day < ?
          AND day >= date(?, '-' || ? || ' days')
          AND day = (SELECT MIN(day) FROM debt_snapshot
                     WHERE project = ? AND day < ?
                       AND day >= date(?, '-' || ? || ' days'));
        """, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in [project, day, day].enumerated() { bindText(stmt, Int32(index + 1), value) }
        sqlite3_bind_int64(stmt, 4, Int64(days))
        bindText(stmt, 5, project)
        bindText(stmt, 6, day)
        bindText(stmt, 7, day)
        sqlite3_bind_int64(stmt, 8, Int64(days))

        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
        }
        return out
    }

    /// A kind's daily counts for a project, oldest first — the raw trend series.
    public func debtTrend(project: String, kind: String, days: Int = 30) -> [(day: String, count: Int)] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
        SELECT day, count FROM debt_snapshot
        WHERE project = ? AND kind = ? AND day >= date('now', 'localtime', '-' || ? || ' days')
        ORDER BY day;
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, project)
        bindText(stmt, 2, kind)
        sqlite3_bind_int64(stmt, 3, Int64(days))

        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((String(cString: sqlite3_column_text(stmt, 0)),
                        Int(sqlite3_column_int64(stmt, 1))))
        }
        return out
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw IndexStoreError.step(message)
        }
    }

    private func scalar(_ sql: String) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT)
    }
}
