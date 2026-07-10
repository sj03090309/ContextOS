import Foundation

/// Detects whether an AI agent is *actively processing a command right now* by
/// watching its session logs. Claude Code appends every user message and
/// assistant/tool event to `~/.claude/projects/<project>/<session>.jsonl` as it
/// works, and Codex CLI does the same under `~/.codex/sessions` — so "a session
/// log was modified in the last few seconds" is exactly "the user hit enter and
/// the agent is still working".
///
/// Pure filesystem stats, no parsing. A cheap two-level strategy keeps the
/// steady-state cost tiny: remember the hot file that was recently active and
/// stat just that one; rescan the trees only when the hot file goes quiet.
public final class AgentActivityMonitor: @unchecked Sendable {

    private let home: URL
    private var hotFiles: [URL] = []
    private var lastScan = Date.distantPast
    private let lock = NSLock()

    /// How long a directory can be untouched before we stop descending into it.
    /// A live session's file was created recently, so its parent dir is fresh.
    private let staleDirWindow: TimeInterval = 7 * 86_400

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// True when any known agent session log was modified within `window`.
    public func isActive(within window: TimeInterval = 6, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Fast path: the sessions that were active moments ago.
        if hotFiles.contains(where: { mtime($0).map { now.timeIntervalSince($0) <= window } == true }) {
            return true
        }

        // Rescan at most every 4s — between scans a brand-new session is caught
        // on the next pass, which at a 2s UI tick is unnoticeable.
        guard now.timeIntervalSince(lastScan) >= 4 else { return false }
        lastScan = now

        var newest: [(URL, Date)] = []
        for file in candidateLogs(now: now) {
            if let m = mtime(file) { newest.append((file, m)) }
        }
        newest.sort { $0.1 > $1.1 }
        hotFiles = newest.prefix(4).map(\.0)

        return newest.first.map { now.timeIntervalSince($0.1) <= window } ?? false
    }

    // MARK: - Log discovery

    /// Session log files from every supported agent, pruned to fresh directories.
    private func candidateLogs(now: Date) -> [URL] {
        var files: [URL] = []
        // Claude Code: projects/<encoded-project>/<session>.jsonl
        files += logs(underDirsOf: home.appendingPathComponent(".claude/projects"),
                      suffix: ".jsonl", now: now)
        // Codex CLI: sessions/<year>/<month>/<day>/rollout-*.jsonl (depth varies).
        files += logs(recursivelyUnder: home.appendingPathComponent(".codex/sessions"),
                      suffix: ".jsonl", now: now)
        return files
    }

    /// Files one level below `root` (Claude Code layout), skipping stale dirs.
    private func logs(underDirsOf root: URL, suffix: String, now: Date) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var out: [URL] = []
        for dir in dirs {
            guard let dirDate = mtime(dir), now.timeIntervalSince(dirDate) <= staleDirWindow,
                  let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            out += entries.filter { $0.lastPathComponent.hasSuffix(suffix) }
        }
        return out
    }

    /// Recursive variant (Codex's dated tree), pruning stale directories so old
    /// months are never descended into.
    private func logs(recursivelyUnder root: URL, suffix: String, now: Date) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var stack = [root]
        while let dir = stack.popLast() {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
            else { continue }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if let d = mtime(entry), now.timeIntervalSince(d) <= staleDirWindow {
                        stack.append(entry)
                    }
                } else if entry.lastPathComponent.hasSuffix(suffix) {
                    out.append(entry)
                }
            }
        }
        return out
    }

    private func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
