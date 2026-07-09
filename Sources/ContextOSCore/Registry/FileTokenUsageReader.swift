import Foundation

/// Per-file token usage attributed to an AI agent, derived from local transcripts.
public struct FileTokenUsage: Sendable, Identifiable {
    public var path: String       // absolute file path as referenced by the agent
    public var agent: String      // e.g. "Claude Code"
    public var tokens: Int        // estimated tokens this file loaded into context
    public var loads: Int         // how many times it was read/edited

    public init(path: String, agent: String, tokens: Int, loads: Int) {
        self.path = path
        self.agent = agent
        self.tokens = tokens
        self.loads = loads
    }

    public var id: String { agent + "\u{1}" + path }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// A short "parent/name" label for compact display.
    public var shortLabel: String {
        let ns = path as NSString
        let name = ns.lastPathComponent
        let parent = (ns.deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty ? name : parent + "/" + name
    }
}

/// Reads Claude Code transcripts and attributes context tokens to the files the
/// agent loaded (via Read/Edit/Write tool calls) — i.e. how many tokens each file
/// cost by being pulled into context.
///
/// Purely local: it parses the user's own transcripts on disk. Only Claude Code
/// exposes a local transcript format, so it's the one agent with real per-file
/// data today; `FileTokenUsage.agent` leaves room to add other sources later.
public enum FileTokenUsageReader {

    public static let claudeAgentName = "Claude Code"

    private static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    private static let estimator = TokenEstimator()
    private static let fileTools: Set<String> = ["Read", "Edit", "Write", "NotebookEdit"]

    /// Top files by tokens loaded into context, across all projects, newest data.
    public static func topFiles(limit: Int = 8) -> [FileTokenUsage] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return [] }

        var totals: [String: (tokens: Int, loads: Int)] = [:]
        for dir in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                for (path, v) in perFile(for: file) {
                    var cur = totals[path] ?? (0, 0)
                    cur.tokens += v.tokens; cur.loads += v.loads
                    totals[path] = cur
                }
            }
        }

        return totals
            .map { FileTokenUsage(path: $0.key, agent: claudeAgentName, tokens: $0.value.tokens, loads: $0.value.loads) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Per-transcript cache (keyed by mtime+size)

    // Transcripts are large and append-only; cache each file's parse result so
    // only changed transcripts are re-parsed on refresh.
    private struct Cached { var mtime: TimeInterval; var size: Int; var perFile: [String: (tokens: Int, loads: Int)] }
    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    private static func perFile(for file: URL) -> [String: (tokens: Int, loads: Int)] {
        let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = vals?.fileSize ?? 0
        let key = file.path

        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit, hit.mtime == mtime, hit.size == size { return hit.perFile }

        var result: [String: (tokens: Int, loads: Int)] = [:]
        var pending: [String: String] = [:]   // tool_use_id → file_path

        if let raw = try? String(contentsOf: file, encoding: .utf8) {
            raw.enumerateLines { line, _ in
                guard line.contains("tool_use") || line.contains("tool_result") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let message = (obj["message"] as? [String: Any]) ?? obj
                guard let items = message["content"] as? [[String: Any]] else { return }

                for item in items {
                    switch item["type"] as? String {
                    case "tool_use":
                        if let name = item["name"] as? String, fileTools.contains(name),
                           let id = item["id"] as? String,
                           let input = item["input"] as? [String: Any],
                           let path = input["file_path"] as? String {
                            pending[id] = path
                        }
                    case "tool_result":
                        if let id = item["tool_use_id"] as? String, let path = pending[id] {
                            pending[id] = nil
                            let ext = (path as NSString).pathExtension
                            let tokens = estimator.estimate(text: resultText(item["content"]),
                                                            language: Language.detect(fromExtension: ext))
                            var cur = result[path] ?? (0, 0)
                            cur.tokens += tokens; cur.loads += 1
                            result[path] = cur
                        }
                    default:
                        break
                    }
                }
            }
        }

        lock.lock(); cache[key] = Cached(mtime: mtime, size: size, perFile: result); lock.unlock()
        return result
    }

    /// A tool_result's `content` may be a plain string or an array of text blocks.
    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}
