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
    private var hottest: (url: URL, mtime: Date)?
    private var lastScan = Date.distantPast
    private let lock = NSLock()

    /// How long a directory can be untouched before we stop descending into it.
    /// A live session's file was created recently, so its parent dir is fresh.
    private let staleDirWindow: TimeInterval = 7 * 86_400

    /// A log whose last event is an *unanswered* tool call keeps the session
    /// "active" for up to this long even with no writes — one long-running tool
    /// (a build, a test suite, a big install) produces no log lines until it
    /// returns. Generous enough to cover essentially any real tool; the cap
    /// only bounds the failure mode where the agent died mid-tool, so a pending
    /// call doesn't pin the mascot on forever.
    private let pendingToolCap: TimeInterval = 15 * 60

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// True when an agent is actively processing a command. Two tiers:
    ///   1. The hottest session log was written within `window` — covers the
    ///      user's message, the agent thinking, and streamed output.
    ///   2. It's been quiet longer than that, but the log's last event is a
    ///      tool call with no result yet — the agent is *waiting on a tool
    ///      right now* (a long build/test), which writes nothing until it ends.
    public func isActive(within window: TimeInterval = 20, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Refresh which file is hottest at most every 4s; between scans we reuse
        // the last hottest file and just re-stat it (cheap, catches new writes).
        if now.timeIntervalSince(lastScan) >= 4 || hottest == nil {
            lastScan = now
            var newest: (URL, Date)?
            for file in candidateLogs(now: now) {
                guard let m = mtime(file) else { continue }
                if newest == nil || m > newest!.1 { newest = (file, m) }
            }
            hottest = newest
        } else if let h = hottest, let m = mtime(h.url) {
            hottest = (h.url, m)   // re-stat the known hot file for fresh mtime
        }

        guard let h = hottest else { return false }
        let quiet = now.timeIntervalSince(h.mtime)
        if quiet <= window { return true }
        // Long-tool tier: only worth a tail read while the session is plausibly
        // still alive, and only pays the read during the quiet gaps.
        if quiet <= pendingToolCap, Self.hasPendingToolCall(h.url) { return true }
        return false
    }

    // MARK: - Pending tool-call detection

    /// Whether the tail of a Claude Code / Codex session log ends on a tool call
    /// that hasn't been answered — i.e. a tool is running right now. Reads only
    /// the last slice of the file and matches `tool_use` ids against the
    /// `tool_use_id`s of later `tool_result` blocks.
    static func hasPendingToolCall(_ url: URL, tailBytes: Int = 128 * 1024) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return false
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // If we started mid-file, the first line is probably a fragment — drop it.
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        var openToolUseIDs = Set<String>()
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }
            for block in content {
                switch block["type"] as? String {
                case "tool_use":
                    if let id = block["id"] as? String { openToolUseIDs.insert(id) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { openToolUseIDs.remove(id) }
                default:
                    break
                }
            }
        }
        return !openToolUseIDs.isEmpty
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
