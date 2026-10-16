import Foundation
import CryptoKit
import ContextOSUsage

/// Metadata-only accounting. Decodable deliberately has no text, prompt,
/// arguments, output, or credential fields. Raw JSONL bytes stay transient.
/// App presence is supplied separately by AppKit and never affects accounting.
public final class ConcurrentUsageReader: @unchecked Sendable {
    private struct Counter: Decodable {
        var input_tokens: Int64?
        var output_tokens: Int64?
        var cached_input_tokens: Int64?
        var cache_read_input_tokens: Int64?
        var cache_creation_input_tokens: Int64?
        var total_tokens: Int64?
        func total(claude: Bool) -> Int64? {
            let fields = [input_tokens, output_tokens, cached_input_tokens,
                          cache_read_input_tokens, cache_creation_input_tokens, total_tokens].compactMap { $0 }
            guard fields.allSatisfy({ $0 >= 0 }), !fields.isEmpty else { return nil }
            if !claude { return total_tokens } // Includes cached input + reasoning; do not add them again.
            guard let input_tokens, let output_tokens else { return nil }
            return [input_tokens, output_tokens, cache_read_input_tokens ?? 0,
                    cache_creation_input_tokens ?? 0].reduce(0, UsageNumbers.add)
        }
    }
    private struct Block: Decodable { var type: String?; var id: String?; var tool_use_id: String? }
    private struct Message: Decodable {
        var id: String?; var model: String?; var usage: Counter?; var stop_reason: String?
        var blocks: [Block] = []; var hasContent = false
        enum CodingKeys: String, CodingKey { case id, model, usage, stop_reason, content }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            usage = try c.decodeIfPresent(Counter.self, forKey: .usage)
            stop_reason = try c.decodeIfPresent(String.self, forKey: .stop_reason)
            hasContent = c.contains(.content)
            // A string content is deliberately never decoded.
            blocks = (try? c.decode([Block].self, forKey: .content)) ?? []
        }
    }
    private struct Info: Decodable { var total_token_usage: Counter? }
    private struct Payload: Decodable {
        var type: String?; var id: String?; var cwd: String?; var model: String?; var turn_id: String?
        var role: String?; var phase: String?; var call_id: String?
        var forked_from_id: String?; var info: Info?
    }
    private struct Envelope: Decodable {
        var type: String?; var timestamp: String?; var sessionId: String?; var uuid: String?
        var cwd: String?; var isMeta: Bool?; var isSidechain: Bool?
        var message: Message?; var payload: Payload?
    }
    private struct Metric {
        var date: Date; var tokens: Int64; var model: String; var project: String; var cumulative: Int64? = nil; var sequence = 0
    }
    private struct Row {
        var inode: UInt64 = 0; var offset = 0; var size = 0; var mtime = Date.distantPast
        var session = ""; var model = "모델 미상"; var project = "프로젝트 미상"
        var previous: Int64 = 0; var seen = Set<String>(); var metrics: [String: Metric] = [:]
        var lastEvent: Date?; var phase: WorkState = .unknown; var pending = Set<String>()
        var partial = false; var inherited = false
        var skippingLongLine = false
        var needsMoreRead = false
        var runEvents = Set<ExplicitAIRunEvent>()
        var runIncomplete = false
    }
    private var rows: [String: Row] = [:]
    private struct MemoKey: Equatable {
        var revision: UInt64; var day: Date; var zone: String
        var live: Set<String>; var discovery: [CollectionState]
    }
    private var memo: (key: MemoKey, value: ConcurrentUsageSnapshot, phases: [String: WorkState])?
    private var revision: UInt64 = 0
    private var readBudget = 0
    private let maximumFilesPerProvider: Int
    private let maximumMetrics: Int
    private let maximumLineBytes: Int
    private let maximumReadBytes: Int
    private let lock = NSLock()
    public init(maximumFilesPerProvider: Int = 128, maximumMetrics: Int = 20_000,
                maximumLineBytes: Int = 2 * 1024 * 1024, maximumReadBytes: Int = 4 * 1024 * 1024) {
        self.maximumFilesPerProvider = max(1, min(128, maximumFilesPerProvider))
        self.maximumMetrics = max(1, min(20_000, maximumMetrics))
        self.maximumLineBytes = max(16, min(2 * 1024 * 1024, maximumLineBytes))
        self.maximumReadBytes = max(self.maximumLineBytes + 16, min(4 * 1024 * 1024, maximumReadBytes))
    }

    public func snapshot(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         now: Date = Date(), timeZone: TimeZone = .current) -> ConcurrentUsageSnapshot {
        lock.lock(); defer { lock.unlock() }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        var dayTotals: [Date: Int64] = [:], agentTotals: [String: Int64] = [:]
        var modelTotals: [String: Int64] = [:], projectTotals: [String: Int64] = [:]
        var providers: [UsageProvider] = [], sessions: [ObservedSession] = []
        let sources = [("Codex", ".codex/sessions", false), ("Claude Code", ".claude/projects", true)]
        let discoveries = sources.map { discover(root: home.appendingPathComponent($0.1), claude: $0.2) }
        var live = Set(discoveries.flatMap { $0.files.map(\.path) })
        rows = rows.filter { live.contains($0.key) }
        readBudget = maximumReadBytes
        var discoveryStates: [CollectionState] = []
        var decodedRows: [(String, [String: Row], CollectionState, Date?)] = []
        var readFailure = false
        for (index, source) in sources.enumerated() {
            let (agent, _, claude) = source
            let discovery = discoveries[index]
            var state = discovery.state
            discoveryStates.append(state)
            var latest: Date?
            var merged: [String: Row] = [:]
            for file in discovery.files {
                live.insert(file.path)
                guard let row = read(file: file, claude: claude, now: now) else { state = .partial; readFailure = true; continue }
                if row.partial || row.inherited || row.needsMoreRead { state = .partial }
                if let date = row.lastEvent { latest = max(latest ?? date, date) }
                guard !row.session.isEmpty else { state = .partial; continue }
                let identity = agent + ":" + row.session
                if var old = merged[identity] {
                    var combined = old.metrics
                    for (key, metric) in row.metrics {
                        if let previous = combined[key] {
                            // Cumulative values are reconstructed below. Prefer the
                            // copy with more preceding accounting events, not a
                            // larger file-local delta from a truncated copy.
                            if metric.cumulative != nil ? previous.sequence < metric.sequence : previous.tokens < metric.tokens { combined[key] = metric }
                        } else { combined[key] = metric }
                    }
                    let combinedRuns = old.runEvents.union(row.runEvents)
                    let incompleteRuns = old.runIncomplete || row.runIncomplete
                    if (row.lastEvent ?? .distantPast) > (old.lastEvent ?? .distantPast) { old = row }
                    old.metrics = combined
                    old.runEvents = combinedRuns
                    old.runIncomplete = incompleteRuns
                    old.partial = old.partial || row.partial
                    old.needsMoreRead = old.needsMoreRead || row.needsMoreRead
                    merged[identity] = old
                } else { merged[identity] = row }
            }
            decodedRows.append((agent, merged, state, latest))
        }
        let key = MemoKey(revision: revision, day: today, zone: timeZone.identifier,
                          live: live, discovery: discoveryStates)
        if !readFailure, let memo, memo.key == key {
            var value = memo.value
            value.widget.generatedAt = now
            value.aiExecution = ExplicitAIRuns.summarize(decodedRows.filter { $0.0 == "Codex" }.flatMap { source in
                source.1.flatMap { identity, row in row.runEvents.map { ExplicitAIRunEvent(id: identity + ":" + $0.id, kind: $0.kind, date: $0.date) } }
            }, now: now, timeZone: timeZone, incomplete: memo.value.aiExecution.state == .partial,
                available: discoveries[0].state != .unavailable)
            value.sessions = value.sessions.map { session in
                var s = session
                s.state = Self.aged(memo.phases[s.id] ?? .unknown, last: s.lastEvent, now: now)
                return s
            }
            return value
        }
        var phases: [String: WorkState] = [:]
        var runEvents: [ExplicitAIRunEvent] = []
        var runIncomplete = decodedRows.first?.2 == .partial
        for (agent, merged, initialState, latest) in decodedRows {
            var state = initialState
            var hasAccounting = false
            for (identity, row) in merged {
                if agent == "Codex" {
                    runEvents += row.runEvents.map { .init(id: identity + ":" + $0.id, kind: $0.kind, date: $0.date) }
                    runIncomplete = runIncomplete || row.runIncomplete || row.partial || row.inherited || row.needsMoreRead
                }
                var total: Int64?, todayTotal: Int64?, previous: Int64 = 0
                // Reconstruct one canonical counter stream across copied/resumed files.
                // Claude messages choose the largest observed streamed total per message ID.
                let ordered = row.metrics.sorted(by: {
                    if $0.value.date != $1.value.date { return $0.value.date < $1.value.date }
                    if $0.value.sequence != $1.value.sequence { return $0.value.sequence < $1.value.sequence }
                    return $0.key < $1.key
                })
                var metricIndex = 0
                while metricIndex < ordered.count {
                    var metric = ordered[metricIndex].value
                    metricIndex += 1
                    while metricIndex < ordered.count {
                        let next = ordered[metricIndex].value
                        guard next.date == metric.date, next.sequence == metric.sequence,
                              let nextCounter = next.cumulative, let counter = metric.cumulative else { break }
                        // Independent fragments do not establish order. Retain
                        // their observed high-water counter, not a guessed reset.
                        state = .partial
                        if nextCounter > counter { metric = next }
                        metricIndex += 1
                    }
                    let tokens: Int64
                    if let cumulative = metric.cumulative {
                        tokens = cumulative < previous ? cumulative : cumulative - previous
                        previous = cumulative
                    } else { tokens = metric.tokens }
                    hasAccounting = true
                    total = UsageNumbers.add(total ?? 0, tokens)
                    let day = calendar.startOfDay(for: metric.date)
                    if day >= start && day <= today {
                        dayTotals[day] = UsageNumbers.add(dayTotals[day] ?? 0, tokens)
                        projectTotals[metric.project] = UsageNumbers.add(projectTotals[metric.project] ?? 0, tokens)
                    }
                    if day == today {
                        todayTotal = UsageNumbers.add(todayTotal ?? 0, tokens)
                        agentTotals[agent] = UsageNumbers.add(agentTotals[agent] ?? 0, tokens)
                        let modelKey = agent + " · " + metric.model
                        modelTotals[modelKey] = UsageNumbers.add(modelTotals[modelKey] ?? 0, tokens)
                    }
                }
                var phase = row.phase
                if row.partial || row.inherited || row.needsMoreRead || row.lastEvent == nil { phase = .unknown }
                let id = Self.digest(identity)
                phases[id] = phase
                sessions.append(ObservedSession(id: id, agent: agent,
                    project: row.project, model: row.model, state: Self.aged(phase, last: row.lastEvent, now: now), lastEvent: row.lastEvent,
                    todayTokens: todayTotal, totalTokens: total))
            }
            if state == .ready && !hasAccounting { state = .noRecords }
            providers.append(.init(name: agent, state: state, latestEvent: latest))
        }
        rows = rows.filter { live.contains($0.key) }
        providers += ["Gemini CLI", "Cursor", "GitHub Copilot"].map { .init(name: $0, state: .unsupported) }
        let days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            return UsageDay(date: date, tokens: dayTotals[date])
        }
        func ranks(_ values: [String: Int64]) -> [UsageRank] {
            values.map { UsageRank($0.key, $0.value) }.sorted {
                $0.tokens == $1.tokens ? $0.name < $1.name : $0.tokens > $1.tokens
            }.prefix(3).map { $0 }
        }
        let value = ConcurrentUsageSnapshot(widget: .init(generatedAt: now, timeZoneID: timeZone.identifier,
            days: days, models: ranks(modelTotals), agents: ranks(agentTotals), projects: ranks(projectTotals),
            providers: providers),
            sessions: sessions.sorted { ($0.lastEvent ?? .distantPast) > ($1.lastEvent ?? .distantPast) },
            aiExecution: ExplicitAIRuns.summarize(runEvents, now: now, timeZone: timeZone,
                incomplete: runIncomplete || readFailure, available: discoveries[0].state != .unavailable))
        if !readFailure { memo = (key, value, phases) }
        return value
    }

    private static func aged(_ phase: WorkState, last: Date?, now: Date) -> WorkState {
        guard let last, phase == .working || phase == .waiting else { return phase }
        let age = now.timeIntervalSince(last)
        return age >= 3600 ? .unknown : age >= 20 ? .waiting : phase
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private static func safeLabel(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
    }
    private func discover(root: URL, claude: Bool) -> (files: [URL], state: CollectionState) {
        let fm = FileManager.default
        guard let rootAttrs = try? fm.attributesOfItem(atPath: root.path) else {
            // ENOENT and inaccessible must be distinguished without bypassing permissions.
            do { _ = try fm.contentsOfDirectory(atPath: root.path) }
            catch let e as NSError {
                return ([], e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError ? .noRecords : .unavailable)
            }
            return ([], .unavailable)
        }
        guard rootAttrs[.type] as? FileAttributeType == .typeDirectory else { return ([], .unavailable) }
        var ancestor = root.deletingLastPathComponent()
        while ancestor.path != "/" {
            if let attrs = try? fm.attributesOfItem(atPath: ancestor.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                return ([], .unavailable)
            }
            // Stop before the caller's explicit home (including /tmp's system alias).
            if ancestor.lastPathComponent == ".codex" || ancestor.lastPathComponent == ".claude" { break }
            ancestor.deleteLastPathComponent()
        }
        var failed = false; var files: [(URL, Date)] = []; var entries = 0
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { return ([], .unavailable) }
        for case let file as URL in walker {
            entries += 1
            if entries > 4096 { failed = true; break }
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey]) else { failed = true; continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); failed = true; continue }
            if claude && walker.level > 2 { walker.skipDescendants(); continue }
            guard values.isRegularFile == true, file.pathExtension == "jsonl",
                  claude ? walker.level == 2 : file.lastPathComponent.hasPrefix("rollout-") else { continue }
            files.append((file, values.contentModificationDate ?? .distantPast))
            if files.count > maximumFilesPerProvider {
                files.sort { $0.1 > $1.1 }; files.removeLast(); failed = true
            }
        }
        return (files.sorted { $0.1 > $1.1 }.map(\.0), failed ? (files.isEmpty ? .unavailable : .partial) : .ready)
    }
    private func read(file: URL, claude: Bool, now: Date) -> Row? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        // Permission revocation can leave inode/size/mtime unchanged. Validate
        // access before reusing a cached success; never fall back after denial.
        guard let access = try? FileHandle(forReadingFrom: file) else { return nil }
        try? access.close()
        var row = rows[file.path] ?? Row()
        let oldCount = row.metrics.count + row.runEvents.count
        if row.inode != inode.uint64Value || size.intValue < row.size || (size.intValue == row.size && row.mtime != mtime) { row = Row() }
        if row.inode == inode.uint64Value && row.size == size.intValue && row.mtime == mtime && !row.needsMoreRead { return row }
        guard readBudget > 0 else { return nil }
        let capacity = max(0, min(4096, maximumMetrics - rows.values.reduce(0) { $0 + $1.metrics.count + $1.runEvents.count } + oldCount))
        var skipping = row.skippingLongLine
        let result = LineReader.boundedLines(of: file, from: row.offset, maximumLineBytes: maximumLineBytes,
            maximumReadBytes: readBudget, skippingOversizedLine: &skipping, onSkipped: { row.partial = true }) { bytes in
            guard let e = try? JSONDecoder().decode(Envelope.self, from: Data(bytes)) else { row.partial = true; return }
            self.consume(e, claude: claude, now: now, row: &row, capacity: capacity)
        }
        guard let result else { return nil }
        let count = result.consumed
        readBudget = max(0, readBudget - result.bytesRead)
        row.skippingLongLine = skipping
        row.needsMoreRead = !result.reachedEOF && row.offset + count < size.intValue
        row.offset += count; row.size = size.intValue; row.inode = inode.uint64Value; row.mtime = mtime
        rows[file.path] = row
        revision &+= 1
        return row
    }
    private func consume(_ e: Envelope, claude: Bool, now: Date, row: inout Row, capacity: Int) {
        let p = e.payload
        if claude, e.isSidechain == true { return } // Parent-only scope; avoid subagent double counting.
        if claude, let id = e.sessionId {
            guard id.utf8.count <= 128 else { row.partial = true; return }; row.session = id
        }
        if !claude, e.type == "session_meta" {
            if let id = p?.id {
                guard id.utf8.count <= 128 else { row.partial = true; return }; row.session = id
            }
            if p?.forked_from_id != nil { row.inherited = true }
        }
        if let cwd = e.cwd ?? p?.cwd {
            row.project = Self.safeLabel(URL(fileURLWithPath: cwd).lastPathComponent, fallback: "프로젝트 미상")
                + " · " + Self.digest(cwd).prefix(4)
        }
        // Reserved placeholder records are not model accounting or work signals.
        // Their zero usage must not become a fabricated observed zero/rank.
        if claude, e.message?.model == "<synthetic>" { row.partial = true; return }
        if let model = e.message?.model ?? (e.type == "turn_context" ? p?.model : nil) {
            row.model = Self.safeLabel(model, fallback: "모델 미상")
        }
        guard let stamp = e.timestamp, stamp.utf8.count <= 64, let epoch = TimeKeys.epoch(fromISO8601: stamp) else {
            if e.message?.usage != nil || p?.type == "token_count" { row.partial = true }
            if !claude && ["task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted"].contains(p?.type ?? "") { row.runIncomplete = true }
            return
        }
        let date = Date(timeIntervalSince1970: epoch)
        guard date <= now.addingTimeInterval(300) else { row.partial = true; return }
        let isNewest = date >= (row.lastEvent ?? .distantPast)
        if isNewest {
            let kind = p?.type ?? ""
            if !claude {
                if e.type == "event_msg" {
                    switch kind {
                    case "task_started", "turn_started", "user_message": row.phase = .working; row.pending = []
                    case "task_complete", "turn_complete", "turn_completed": row.phase = .idle; row.pending = []
                    case "turn_aborted", "turn_interrupted", "task_failed", "shutdown": row.phase = .interrupted; row.pending = []
                    case "agent_message", "agent_reasoning": if row.phase != .idle { row.phase = .working }
                    default: break
                    }
                } else if e.type == "response_item", p?.role == "assistant", p?.phase == "final_answer" { row.phase = .idle }
            } else if let message = e.message {
                if e.type == "user", e.isMeta != true, message.hasContent,
                   !message.blocks.contains(where: { $0.type == "tool_result" }) { row.phase = .working }
                if e.type == "assistant" {
                    row.phase = .working
                    if ["end_turn", "stop_sequence"].contains(message.stop_reason) { row.phase = .idle }
                    if message.stop_reason == "max_tokens" { row.phase = .interrupted }
                }
            }
            // Only lifecycle/accounting events establish freshness, never file mtime or PID.
            if ["event_msg", "response_item", "user", "assistant"].contains(e.type) { row.lastEvent = date }
        }
        if !claude, !row.inherited, e.type == "event_msg" {
            let kind: ExplicitAIRunEvent.Kind?
            switch p?.type {
            case "task_started", "turn_started": kind = .start
            case "task_complete", "turn_complete": kind = .end
            case "turn_aborted", "turn_interrupted", "task_failed": kind = .abort
            default: kind = nil
            }
            if let kind {
                if let id = p?.turn_id, !id.isEmpty, id.utf8.count <= 128 {
                    let event = ExplicitAIRunEvent(id: id, kind: kind, date: date)
                    if row.runEvents.contains(event) { /* identical replay */ }
                    else if row.metrics.count + row.runEvents.count < capacity { row.runEvents.insert(event) }
                    else { row.runIncomplete = true }
                } else { row.runIncomplete = true }
            }
        }
        guard !row.inherited else { return } // A fork may inherit cumulative history: exclude with an explicit partial status.
        if claude, let usage = e.message?.usage {
            guard let tokens = usage.total(claude: true), let id = e.message?.id, id.utf8.count <= 128 else { row.partial = true; return }
            let key = "message:" + id
            if let old = row.metrics[key], old.tokens >= tokens { return }
            guard row.metrics[key] != nil || row.metrics.count + row.runEvents.count < capacity else { row.partial = true; return }
            row.metrics[key] = Metric(date: row.metrics[key]?.date ?? date, tokens: tokens,
                                      model: row.model, project: row.project)
        } else if !claude, e.type == "event_msg", p?.type == "token_count", let usage = p?.info?.total_token_usage {
            guard let total = usage.total(claude: false) else { row.partial = true; return }
            let key = "counter:" + stamp + ":" + String(total)
            guard !row.seen.contains(key) else { return }
            guard row.metrics.count + row.runEvents.count < capacity else { row.partial = true; return }
            row.seen.insert(key)
            let delta = total < row.previous ? total : total - row.previous
            row.previous = total
            row.metrics[key] = Metric(date: date, tokens: delta, model: row.model, project: row.project, cumulative: total, sequence: row.metrics.count)
        }
    }
}
