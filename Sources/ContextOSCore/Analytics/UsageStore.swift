import Foundation
import SQLite3

/// A single "optimized a query" event.
public struct UsageEvent: Sendable {
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

/// Local, cross-project analytics DB. Short-lived: open, use, discard.
///
/// Kept entirely separate from the per-project index so analytics survive
/// re-indexing and span every project on the machine.
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
    }

    deinit { sqlite3_close(db) }

    /// Posted (cross-process) right after an optimization is recorded, so a
    /// monitor like the menu-bar app can react in real time instead of polling.
    public static let optimizedNotification = Notification.Name("com.contextos.optimized")

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

    /// Tokens saved per local day for the last `days`, oldest first. Days with
    /// no activity are filled with 0 so charts have a continuous series.
    /// Pass `project` to scope the series to a single project.
    public func dailySaved(project: String? = nil, days: Int = 7) -> [(day: String, saved: Int)] {
        var byDay: [String: Int] = [:]
        var stmt: OpaquePointer?
        let sql = """
        SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS d,
               COALESCE(SUM(MAX(full - selected, 0)), 0)
        FROM usage \(project != nil ? "WHERE project = ?" : "") GROUP BY d;
        """
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if let project { bindText(stmt, 1, project) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                byDay[String(cString: sqlite3_column_text(stmt, 0))] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let cal = Calendar.current
        return (0..<days).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = fmt.string(from: date)
            return (key, byDay[key] ?? 0)
        }
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
