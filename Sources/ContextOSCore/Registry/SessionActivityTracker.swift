import Foundation

public enum AgentWorkPhase: Sendable, Equatable {
    case working, waiting, completed, interrupted, unknown
    public var isWorking: Bool { self == .working || self == .waiting }
}

/// Evidence about one turn. Dates are transcript dates, never an idle timer's date.
public struct SessionActivityStatus: Sendable, Equatable {
    public var session: String
    public var agent: String
    public var project: String?
    public var phase: AgentWorkPhase
    public var startedAt: Date?
    public var lastEventAt: Date?
    public var endedAt: Date?
    public var pendingTools: Int
    public var optimizing: Bool
    public var planning: Bool
    public var recheckAt: Date?
}

public struct SessionActivitySnapshot: Sendable, Equatable {
    public var selected: SessionActivityStatus?
    public var activeSessions: Int
    public var optimizing: Bool
    public var planning: Bool
    public var recheckAt: Date?

    public static let empty = SessionActivitySnapshot(selected: nil, activeSessions: 0,
        optimizing: false, planning: false, recheckAt: nil)
}

enum SessionActivityEvent: Sendable {
    case started, activity, toolStarted(String, String), toolFinished(String), ended, interrupted
}

/// A silence changes working → waiting → unknown; it never invents a completion.
struct SessionTurnState: Sendable {
    static let quietWindow: TimeInterval = 20
    static let staleWindow: TimeInterval = 60 * 60
    var phase: AgentWorkPhase = .unknown
    var startedAt: Date?
    var lastEventAt: Date?
    var endedAt: Date?
    var project: String?
    var pending: [String: String] = [:]
    private var lifecycle = Date.distantPast

    mutating func apply(_ event: SessionActivityEvent, at date: Date, now: Date) {
        // Replayed or delayed events from a finished turn cannot reopen it.
        guard date <= now.addingTimeInterval(300), date >= lifecycle else { return }
        switch event {
        case .started:
            if !phase.isWorking && phase != .unknown && date == lifecycle { return }
            // A repeated start (log replay, duplicate user envelope) is idempotent.
            if startedAt == date { return }
            phase = .working; startedAt = date; endedAt = nil
            pending.removeAll(); lifecycle = date
        case .activity:
            // In a bounded bootstrap tail the original prompt can be absent.
            // A real assistant/tool event is evidence of work, without a made-up start.
            if phase == .unknown { phase = .working }
            guard phase.isWorking else { return }
        case .toolStarted(let id, let name):
            if !phase.isWorking && phase != .unknown && date == lifecycle { return }
            if !phase.isWorking { phase = .working; startedAt = nil; endedAt = nil }
            pending[id] = name
        case .toolFinished(let id):
            guard phase.isWorking else { return }
            pending.removeValue(forKey: id)
        case .ended, .interrupted:
            phase = { if case .ended = event { return .completed }; return .interrupted }()
            endedAt = date; pending.removeAll(); lifecycle = date
        }
        lastEventAt = max(lastEventAt ?? date, date)
    }

    func status(session: String, agent: String, now: Date, readable: Bool = true) -> SessionActivityStatus {
        var shown = readable ? phase : .unknown
        var next: Date?
        if phase.isWorking, readable, let last = lastEventAt {
            let quiet = now.timeIntervalSince(last)
            if quiet >= Self.staleWindow { shown = .unknown }
            else if quiet >= Self.quietWindow {
                shown = .waiting; next = last.addingTimeInterval(Self.staleWindow)
            } else {
                shown = .working; next = last.addingTimeInterval(Self.quietWindow)
            }
        }
        let names = shown.isWorking ? Array(pending.values) : []
        return SessionActivityStatus(session: session, agent: agent, project: project,
            phase: shown, startedAt: startedAt, lastEventAt: lastEventAt, endedAt: endedAt,
            pendingTools: names.count,
            optimizing: names.contains { $0 == "mcp__contextos__read_optimized" },
            planning: names.contains { $0.hasPrefix("mcp__contextos__") && $0 != "mcp__contextos__read_optimized" },
            recheckAt: next)
    }
}

/// Reads only lifecycle/tool metadata. No prompt, code or tool output is retained.
/// Cached per file and incrementally resumed; bootstraps from at most 2 MiB per log.
public final class SessionActivityTracker: @unchecked Sendable {
    private struct Entry {
        var state = SessionTurnState()
        var offset = 0
        var size = 0
        var inode: UInt64 = 0
        var mtime = Date.distantPast
        var readable = true
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let bootstrapBytes: Int

    public init(bootstrapBytes: Int = 2 * 1024 * 1024) {
        self.bootstrapBytes = max(256, bootstrapBytes)
    }

    public func snapshot(logs: [(url: URL, mtime: Date)], now: Date = Date()) -> SessionActivitySnapshot {
        lock.lock(); defer { lock.unlock() }
        // Bounded work at launch; fresh active sessions take priority over history.
        var unique: [String: (url: URL, mtime: Date)] = [:]
        for log in logs {
            let url = log.url.resolvingSymlinksInPath()
            if unique[url.path] == nil || unique[url.path]!.mtime < log.mtime {
                unique[url.path] = (url, log.mtime)
            }
        }
        let selected = unique.values.sorted { $0.mtime > $1.mtime }.prefix(64)
        let paths = Set(selected.map { $0.url.path })
        entries = entries.filter { paths.contains($0.key) }
        var statuses: [SessionActivityStatus] = []
        for log in selected {
            let path = log.url.path
            var entry = entries[path] ?? Entry()
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber else {
                statuses.append(entry.state.status(session: path, agent: Self.agent(path), now: now, readable: false))
                continue
            }
            let bytes = size.intValue
            let mtime = attrs[.modificationDate] as? Date ?? log.mtime
            let changed = entry.inode != inode.uint64Value || entry.size != bytes || entry.mtime != mtime
            if changed {
                let reset = entry.inode != inode.uint64Value || bytes < entry.size
                    || (bytes == entry.size && entry.mtime != mtime)
                if reset {
                    entry = Entry()
                    entry.offset = max(0, bytes - bootstrapBytes)
                }
                var skipFragment = reset && entry.offset > 0
                var incompleteEvidence = false
                let consumed = LineReader.forEachLine(of: log.url, from: entry.offset) { line in
                    if skipFragment { skipFragment = false; return }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        incompleteEvidence = true; return
                    }
                    if !Self.consume(obj, state: &entry.state, now: now) {
                        if ["user", "assistant", "event_msg", "response_item"].contains(obj["type"] as? String ?? "") {
                            incompleteEvidence = true
                        }
                    }
                }
                entry.readable = consumed != nil && !incompleteEvidence
                if let consumed { entry.offset += consumed }
                entry.size = bytes; entry.inode = inode.uint64Value; entry.mtime = mtime
                entries[path] = entry
            }
            var status = entry.state.status(session: path, agent: Self.agent(path), now: now, readable: entry.readable)
            // An unknown or unreadable log is useful evidence of uncertainty, not completion.
            if status.lastEventAt == nil { status.lastEventAt = log.mtime }
            statuses.append(status)
        }
        let active = statuses.filter { $0.phase.isWorking }
        let chosen = (active.isEmpty ? statuses : active).max {
            ($0.lastEventAt ?? .distantPast) < ($1.lastEventAt ?? .distantPast)
        }
        return SessionActivitySnapshot(selected: chosen, activeSessions: active.count,
            optimizing: active.contains { $0.optimizing }, planning: active.contains { $0.planning },
            recheckAt: active.compactMap(\.recheckAt).min())
    }

    private static func agent(_ path: String) -> String {
        path.contains("/.claude/") ? "Claude Code" : "Codex"
    }

    @discardableResult
    static func consume(_ obj: [String: Any], state: inout SessionTurnState, now: Date) -> Bool {
        let type = obj["type"] as? String ?? ""
        let relevant = ["user", "assistant", "event_msg", "response_item"].contains(type)
        let payload = obj["payload"] as? [String: Any] ?? [:]
        if let cwd = (obj["cwd"] as? String) ?? (payload["cwd"] as? String), cwd.hasPrefix("/"),
           let timestamp = obj["timestamp"] as? String,
           let epoch = TimeKeys.epoch(fromISO8601: timestamp),
           epoch <= now.timeIntervalSince1970 + 300,
           epoch >= (state.lastEventAt?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude) {
            state.project = (cwd as NSString).lastPathComponent
        }
        guard relevant else { return true }
        guard let timestamp = obj["timestamp"] as? String,
              let epoch = TimeKeys.epoch(fromISO8601: timestamp),
              epoch <= now.timeIntervalSince1970 + 300 else { return false }
        let at = Date(timeIntervalSince1970: epoch)
        if type == "event_msg" {
            switch payload["type"] as? String {
            case "task_started", "turn_started", "user_message": state.apply(.started, at: at, now: now)
            case "task_complete", "turn_completed": state.apply(.ended, at: at, now: now)
            case "turn_aborted", "turn_interrupted", "task_failed", "shutdown": state.apply(.interrupted, at: at, now: now)
            case "agent_message", "agent_reasoning": state.apply(.activity, at: at, now: now)
            default: break
            }
            return true
        }
        if type == "response_item" {
            let kind = payload["type"] as? String ?? ""
            if let id = payload["call_id"] as? String {
                if ["function_call", "custom_tool_call", "tool_search_call"].contains(kind) {
                    state.apply(.toolStarted(id, payload["name"] as? String ?? ""), at: at, now: now)
                } else if ["function_call_output", "custom_tool_call_output", "tool_search_output"].contains(kind) {
                    state.apply(.toolFinished(id), at: at, now: now)
                }
            } else if kind == "message" {
                if payload["role"] as? String == "user" { state.apply(.started, at: at, now: now) }
                else if payload["role"] as? String == "assistant" {
                    state.apply(payload["phase"] as? String == "final_answer" ? .ended : .activity, at: at, now: now)
                }
            } else if kind == "reasoning" { state.apply(.activity, at: at, now: now) }
            return true
        }
        guard let message = obj["message"] as? [String: Any] else { return false }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let firstText = (message["content"] as? String)
            ?? blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
        if type == "user", firstText.hasPrefix("[Request interrupted by user") {
            state.apply(.interrupted, at: at, now: now); return true
        }
        if type == "user", obj["isMeta"] as? Bool != true,
           !blocks.contains(where: { $0["type"] as? String == "tool_result" }),
           !firstText.isEmpty {
            state.apply(.started, at: at, now: now)
        } else if type == "assistant" { state.apply(.activity, at: at, now: now) }
        for block in blocks {
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                state.apply(.toolStarted(id, block["name"] as? String ?? ""), at: at, now: now)
            } else if block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String {
                state.apply(.toolFinished(id), at: at, now: now)
            }
        }
        if type == "assistant" {
            switch message["stop_reason"] as? String {
            case "end_turn", "stop_sequence": state.apply(.ended, at: at, now: now)
            case "max_tokens": state.apply(.interrupted, at: at, now: now)
            default: break
            }
        }
        return true
    }
}
