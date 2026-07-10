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
    /// Last MCP heartbeat, posted by contextos-mcp on every request it handles.
    private var lastHeartbeat = Date.distantPast
    private var lastQueryCount = -1
    private var timer: Timer?
    private var tick = 0
    private var flashTask: Task<Void, Never>?
    nonisolated(unsafe) private var optimizedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var activityObserver: NSObjectProtocol?

    init() {
        refreshFast()
        refreshSlow()
        refreshWorking()
        // Real-time: the MCP server posts this the instant it records an
        // optimization, so the mascot reacts with no polling lag.
        optimizedObserver = DistributedNotificationCenter.default().addObserver(
            forName: UsageStore.optimizedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onOptimized() }
        }
        // Heartbeat from contextos-mcp on every request it handles: any agent
        // talking to the MCP server counts as "working", instantly.
        activityObserver = DistributedNotificationCenter.default().addObserver(
            forName: UsageStore.activityNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lastHeartbeat = Date()
                self?.working = true
            }
        }
        // Poll: working state every 2s (it drives the mascot, so it must feel
        // immediate), savings every 4s, the heavier AI-usage scan every ~32s.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    deinit {
        if let optimizedObserver {
            DistributedNotificationCenter.default().removeObserver(optimizedObserver)
        }
        if let activityObserver {
            DistributedNotificationCenter.default().removeObserver(activityObserver)
        }
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

    // Is an agent processing a command *right now*? Two signals, either wins:
    //   1. Session-log writes (Claude Code / Codex) — starts the moment the
    //      user hits enter, keeps firing while the agent thinks and streams.
    //   2. A recent MCP heartbeat — covers agents whose logs we can't read.
    //
    // The 20s quiet threshold matters: agents write their logs per *event*
    // (message done, tool call, tool result), so mid-turn gaps of several
    // seconds are normal — a long think or one slow command must not make the
    // mascot doze off and wake up again. Turning on is instant (any write);
    // only turning off waits out the gap.
    private func refreshWorking() {
        let monitor = activityMonitor
        Task {
            let logsFresh = await Self.checkLogs(monitor)   // stat off the main actor
            working = logsFresh || Date().timeIntervalSince(lastHeartbeat) <= 20
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
