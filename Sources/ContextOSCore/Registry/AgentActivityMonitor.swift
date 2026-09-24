import Foundation

/// Detects whether an AI agent is *actively processing a command right now* by
/// watching its session logs. Claude Code appends every user message and
/// assistant/tool event to `~/.claude/projects/<project>/<session>.jsonl` as it
/// works, and Codex CLI does the same under `~/.codex/sessions` — so "a session
/// log was modified in the last few seconds" is exactly "the user hit enter and
/// the agent is still working".
///
/// Pure filesystem stats, no parsing. Two ways to use it:
///   - **Event-driven** (the menu-bar app): a file-event stream on `watchRoots`
///     reports each write through `noteWrite(atPath:)`, so nothing is scanned
///     at all between writes; `rescan()` only runs at startup and when the
///     stream reports it dropped events.
///   - **Polling** (`isActive`): remember the hot file that was recently active
///     and stat just that one; rescan the trees only when the hot file goes quiet.
public final class AgentActivityMonitor: @unchecked Sendable {

    private let home: URL
    private var hottest: (url: URL, mtime: Date)?
    private var lastScan = Date.distantPast
    private let lock = NSLock()

    /// Path prefixes of the two log trees, both as given and with symlinks
    /// resolved — an event stream reports real paths, and `home` may not be one.
    private let claudePrefixes: [String]
    private let codexPrefixes: [String]

    /// How long a directory can be untouched before we stop descending into it.
    /// A live session's file was created recently, so its parent dir is fresh.
    private let staleDirWindow: TimeInterval = 7 * 86_400

    /// A log whose last event is an *unanswered* tool call keeps the session
    /// "active" for up to this long even with no writes — one long-running tool
    /// (a build, a test suite, a big install) produces no log lines until it
    /// returns. Generous enough to cover essentially any real tool; the cap
    /// only bounds the failure mode where the agent died mid-tool, so a pending
    /// call doesn't pin the mascot on forever.
    private let pendingToolCap: TimeInterval = TurnActivity.pendingToolCap

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        claudePrefixes = Self.spellings(of: home.appendingPathComponent(".claude/projects"))
        codexPrefixes = Self.spellings(of: home.appendingPathComponent(".codex/sessions"))
    }

    /// Every way an event stream might spell `root`, each ending in "/": as
    /// given, and fully resolved. FSEvents reports real paths, and `realpath` is
    /// the one that agrees with it — `URL.resolvingSymlinksInPath` strips the
    /// `/private` from `/private/var/...`, which is exactly what FSEvents keeps.
    /// The root need not exist yet: its deepest existing ancestor is resolved
    /// and the rest re-appended.
    private static func spellings(of root: URL) -> [String] {
        let given = root.standardizedFileURL
        var existing = given
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var spellings = [given.path]
        if let resolved = realpath(existing.path, nil) {
            spellings.append(([String(cString: resolved)] + rest).joined(separator: "/"))
            free(resolved)
        }
        var seen = Set<String>()
        return spellings
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
            .filter { seen.insert($0).inserted }
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
            scanLocked(now: now)
        } else if let h = hottest, let m = Self.modificationDate(h.url.path) {
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

    // MARK: - Event-driven use

    /// The two directory trees whose writes mean an agent is working — what a
    /// file-event stream should watch instead of polling `isActive`.
    public var watchRoots: [URL] {
        [home.appendingPathComponent(".claude/projects"),
         home.appendingPathComponent(".codex/sessions")]
    }

    /// The most recently written session log known so far, and when it was
    /// written. Reads no files.
    public var newestLog: (url: URL, mtime: Date)? {
        lock.lock(); defer { lock.unlock() }
        return hottest
    }

    /// Walk both log trees for the newest log — at startup, and whenever an
    /// event stream admits it lost track (dropped events, a replaced root).
    public func rescan(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        scanLocked(now: now)
    }

    /// Record a change an event stream reported at `path`.
    ///
    /// - Returns: whether `path` is a session log this monitor tracks, i.e.
    ///   whether the caller has anything new to evaluate.
    @discardableResult
    public func noteWrite(atPath path: String) -> Bool {
        guard isSessionLog(path), let written = Self.modificationDate(path) else { return false }
        lock.lock(); defer { lock.unlock() }
        if let h = hottest, h.url.path != path, h.mtime > written { return true }
        hottest = (URL(fileURLWithPath: path), written)
        return true
    }

    /// Whether `path` is one of the logs the scan would find: a Claude Code
    /// transcript directly inside a project directory, or any Codex rollout.
    private func isSessionLog(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        for prefix in claudePrefixes where path.hasPrefix(prefix) {
            // projects/<encoded-project>/<session>.jsonl — one level down, like
            // the scan; subagent logs further down are not a session of their own.
            return path.dropFirst(prefix.count).split(separator: "/").count == 2
        }
        return codexPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: - Pending tool-call detection

    /// Whether the tail of a Claude Code / Codex session log ends on a tool call
    /// that hasn't been answered — i.e. a tool is running right now. Reads only
    /// the last slice of the file, then matches each call against its result:
    ///   - Claude Code: assistant `tool_use` (id) vs user `tool_result`
    ///     (tool_use_id), inside `message.content`.
    ///   - Codex: `response_item` `*_call` (call_id) vs `*_call_output`
    ///     (call_id), inside `payload`.
    /// An unmatched call id means that tool is still in flight.
    public static func hasPendingToolCall(_ url: URL, tailBytes: Int = 128 * 1024) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return false }

        // Claude (toolu_…) and Codex (call_…) ids share one set; namespaces
        // don't collide, so a single open/close tally covers both formats.
        var open = Set<String>()
        data.withUnsafeBytes { tail in
            guard let base = tail.baseAddress else { return }
            // If we started mid-file, the first line is probably a fragment — drop it.
            var skipFirst = start > 0
            var lineStart = 0
            while lineStart < tail.count {
                let newline = memchr(base + lineStart, 0x0A, tail.count - lineStart)
                let lineEnd = newline.map { base.distance(to: UnsafeRawPointer($0)) } ?? tail.count
                defer { lineStart = lineEnd + 1 }
                guard lineEnd > lineStart else { continue }
                if skipFirst { skipFirst = false; continue }

                let line = UnsafeRawBufferPointer(start: base + lineStart, count: lineEnd - lineStart)
                // Only a call or a result can change the tally, and every one
                // names its id — so the rest, most of a busy log, is never decoded.
                guard LineReader.contains(line, "tool_use") || LineReader.contains(line, "tool_result")
                        || LineReader.contains(line, "call_id"),
                      let obj = try? JSONSerialization.jsonObject(
                        with: Data(bytes: line.baseAddress!, count: line.count)) as? [String: Any]
                else { continue }

                // Claude Code: message.content blocks.
                if let message = obj["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        switch block["type"] as? String {
                        case "tool_use":    if let id = block["id"] as? String { open.insert(id) }
                        case "tool_result": if let id = block["tool_use_id"] as? String { open.remove(id) }
                        default: break
                        }
                    }
                }

                // Codex: response_item envelope, calls/outputs linked by call_id.
                if obj["type"] as? String == "response_item",
                   let payload = obj["payload"] as? [String: Any],
                   let callID = payload["call_id"] as? String {
                    switch payload["type"] as? String {
                    case "function_call", "custom_tool_call", "tool_search_call":
                        open.insert(callID)
                    case "function_call_output", "custom_tool_call_output", "tool_search_output":
                        open.remove(callID)
                    default: break
                    }
                }
            }
        }
        return !open.isEmpty
    }

    // MARK: - Log discovery

    private func scanLocked(now: Date) {
        lastScan = now
        var newest: (URL, Date)?
        for file in candidateLogs(now: now) {
            guard let m = mtime(file) else { continue }
            if newest == nil || m > newest!.1 { newest = (file, m) }
        }
        hottest = newest
    }

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

    /// The modification date prefetched with a directory listing.
    private func mtime(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// A file's modification date, read from disk now.
    ///
    /// Not `URL.resourceValues`: NSURL memoizes those on the instance, so asking
    /// the same URL again returns the date from the first ask, and a write to the
    /// hot file would go unnoticed until the next rescan replaced the URL.
    static func modificationDate(_ path: String) -> Date? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}
