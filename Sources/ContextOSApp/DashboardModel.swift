import Foundation
import AppKit
import ContextOSCore

/// Drives the menu-bar **monitor**. Optimization itself runs automatically via
/// the MCP server inside Claude Code — this panel just shows the results:
/// tokens saved, connected AI tools, and AI token usage.
@MainActor
final class DashboardModel: ObservableObject {

    @Published var todaySaved = 0
    @Published var totalSaved = 0
    @Published var queryCount = 0
    @Published var aiTokens = 0
    @Published var agents: [DetectedAgent] = []
    @Published var connected = false
    /// Token usage grouped by project, broken down per AI agent.
    @Published var projectUsage: [ProjectAIUsage] = []
    /// Tokens saved per day for the last 7 days (oldest → today).
    @Published var daily: [DayPoint] = []
    /// Most recent optimization events, newest first.
    @Published var recent: [UsageEvent] = []
    /// Brief highlight when MCP just handled an optimization (energetic burst).
    @Published var flashing = false
    /// An AI agent is actively processing a command *right now* — from the
    /// moment the user hits enter until the response settles. Detected two
    /// ways: session-log writes (Claude Code/Codex, catches the very first
    /// keystroke of a turn) and MCP request heartbeats (any agent).
    @Published var working = false

    private let activityMonitor = AgentActivityMonitor()
    /// Last MCP heartbeat / activity signal (posted by contextos-mcp and the
    /// UserPromptSubmit hook). Also the "turn start" time.
    private var lastActivity = Date.distantPast
    /// Last "turn ended" signal (the Stop hook). When this is newer than
    /// `lastActivity`, the agent finished and the mascot should stop *now*.
    private var lastStop = Date.distantPast
    private var lastQueryCount = -1
    private var timer: Timer?
    private var tick = 0
    private var flashTask: Task<Void, Never>?
    nonisolated(unsafe) private var optimizedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activityObserver: NSObjectProtocol?
    nonisolated(unsafe) private var startObserver: NSObjectProtocol?
    nonisolated(unsafe) private var stopObserver: NSObjectProtocol?

    init() {
        refreshFast()
        refreshSlow()
        refreshWorking()
        let center = DistributedNotificationCenter.default()
        // Real-time: the MCP server posts this the instant it records an
        // optimization, so the mascot reacts with no polling lag.
        optimizedObserver = center.addObserver(
            forName: UsageStore.optimizedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onOptimized() }
        }
        // Turn START — the UserPromptSubmit hook fires the instant the user hits
        // enter. Start eating immediately.
        startObserver = center.addObserver(
            forName: UsageStore.turnStartNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastActivity = Date(); self?.working = true }
        }
        // Turn STOP — the Stop hook fires the instant the agent finishes. Stop now.
        stopObserver = center.addObserver(
            forName: UsageStore.turnStopNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastStop = Date(); self?.working = false }
        }
        // MCP heartbeat on every request: keeps a hook-less agent's turn alive.
        activityObserver = center.addObserver(
            forName: UsageStore.activityNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastActivity = Date(); self?.working = true }
        }
        // Poll: working state every 2s (fallback for agents without our hooks),
        // savings every 4s, the heavier AI-usage scan every ~32s.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        [optimizedObserver, activityObserver, startObserver, stopObserver]
            .compactMap { $0 }.forEach { center.removeObserver($0) }
    }

    // Instant reaction to a just-recorded optimization: light up now, refresh the
    // numbers right away.
    private func onOptimized() {
        flash()
        refreshFast()
    }

    /// Manual refresh (e.g. from the ↻ button): do everything now.
    func refresh() { refreshFast(); refreshSlow() }

    private func onTick() {
        tick += 1
        refreshWorking()
        if tick % 2 == 0 { refreshFast() }
        if tick % 16 == 0 { refreshSlow() }
    }

    // Fallback poll (every 2s) for agents without our Stop hook — e.g. Codex.
    // The hooks give Claude Code exact, instant start/stop; this only fills in
    // when they're absent. Crucially, an explicit Stop wins: once the turn ended
    // we do NOT let the 20s session-log tail resurrect "working".
    private func refreshWorking() {
        // Explicit turn boundary from the hooks takes precedence.
        if lastStop > lastActivity {
            working = false          // finished — stay stopped until the next turn
            return
        }
        let monitor = activityMonitor
        Task {
            let logsFresh = await Self.checkLogs(monitor)   // stat off the main actor
            if lastStop > lastActivity { working = false; return }
            working = logsFresh || Date().timeIntervalSince(lastActivity) <= 20
        }
    }

    private nonisolated static func checkLogs(_ monitor: AgentActivityMonitor) async -> Bool {
        monitor.isActive(within: 20)
    }

    // Cheap: savings counters from the local usage DB.
    private func refreshFast() {
        Task {
            let s = await Self.loadSavings()
            todaySaved = s.todaySaved
            totalSaved = s.totalSaved
            daily = s.daily
            recent = s.recent
            if lastQueryCount >= 0, s.queryCount > lastQueryCount { flash() }
            lastQueryCount = s.queryCount
            queryCount = s.queryCount
        }
    }

    // Heavier: AI token usage (parses session logs) + agent detection + per-file
    // token breakdown.
    private func refreshSlow() {
        Task {
            let a = await Self.loadAgentsAndUsage()
            aiTokens = a.aiTokens
            agents = a.agents
            connected = a.connected
            projectUsage = a.projectUsage
        }
    }

    // Show the bolt while ContextOS is actively working. Each new optimization
    // keeps it lit; it reverts to sparkles ~6s after the last activity, so during
    // a busy Claude Code session the bolt stays on.
    private func flash() {
        flashing = true
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { self?.flashing = false }
        }
    }

    struct DayPoint: Sendable, Identifiable {
        var day: String     // yyyy-MM-dd
        var saved: Int
        var label: String   // Korean weekday, e.g. "월"
        var isToday: Bool
        var id: String { day }
    }

    struct Savings: Sendable {
        var todaySaved = 0, totalSaved = 0, queryCount = 0
        var daily: [DayPoint] = []
        var recent: [UsageEvent] = []
    }
    struct AgentsUsage: Sendable {
        var aiTokens = 0
        var agents: [DetectedAgent] = []
        var connected = false
        var projectUsage: [ProjectAIUsage] = []
    }

    // DateFormatter construction is expensive; build once, not on every 4s tick.
    private nonisolated static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private nonisolated static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "EEEEE"     // narrow: 월/화/수/목/금/토/일
        return f
    }()

    private nonisolated static func loadSavings() async -> Savings {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return Savings() }
        let s = store.summary()

        let todayKey = dayParser.string(from: Date())
        let daily = store.dailySaved(days: 7).map { point in
            DayPoint(day: point.day, saved: point.saved,
                     label: dayParser.date(from: point.day).map { weekdayFormatter.string(from: $0) } ?? "",
                     isToday: point.day == todayKey)
        }

        return Savings(todaySaved: store.todaySaved(), totalSaved: s.totalSaved,
                       queryCount: s.queryCount, daily: daily,
                       recent: store.recentEvents(limit: 6))
    }

    private nonisolated static func loadAgentsAndUsage() async -> AgentsUsage {
        let ai = ClaudeUsageReader.totalUsageAllProjects()
        return AgentsUsage(aiTokens: ai.tokens,
                           agents: AgentDetector.detect(),
                           connected: ClaudeIntegration.isGloballyInstalled(),
                           projectUsage: ProjectAITokenReader.topProjects())
    }
}
