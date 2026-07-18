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
    /// AI tokens per local day (`yyyy-MM-dd`), for the calendar.
    @Published var tokensByDay: [String: Int] = [:]
    /// Code shipped over the last 7 days.
    @Published var week = BuildSummary()
    /// Most recent optimization events, newest first.
    @Published var recent: [UsageEvent] = []
    /// Chew state, shared by the menu-bar glyph and the dashboard blob so the
    /// two 뭉치 move as one. Both derive their motion from this plus the
    /// absolute clock; neither keeps its own timeline.
    let mascot = MascotState()

    /// Brief highlight when MCP just handled an optimization (energetic burst).
    @Published var flashing = false { didSet { syncMascot() } }
    /// An AI agent is actively processing a command *right now* — from the
    /// moment the user hits enter until the response settles. Detected two
    /// ways: session-log writes (Claude Code/Codex, catches the very first
    /// keystroke of a turn) and MCP request heartbeats (any agent).
    @Published var working = false { didSet { syncMascot() } }

    /// One place decides whether 뭉치 is eating, so the two renderers can never
    /// disagree about it.
    private func syncMascot() { mascot.set(eating: flashing || working) }

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

    /// Manual refresh (the ↻ button): rebuild everything from disk now, rather
    /// than serving whatever the memo last computed.
    func refresh() { refreshFast(); refreshSlow(force: true) }

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
        // Explicit turn boundary from the hooks takes precedence: once a Stop
        // has landed, nothing reopens the turn until the next real activity
        // (a UserPromptSubmit or a tool-call heartbeat) arrives *after* it.
        if lastStop > lastActivity {
            set(&working, false)     // finished — stay stopped until the next turn
            return
        }
        let monitor = activityMonitor
        Task {
            let logsFresh = await Self.checkLogs(monitor)   // stat off the main actor
            // Re-check after the await: a Stop may have arrived while we were
            // statting. The 20s session-log tail must not revive a turn the
            // Stop hook already closed — Claude Code keeps touching the log for
            // a moment after it finishes, which is exactly what used to keep the
            // mascot eating with nothing being asked.
            guard lastStop <= lastActivity else { set(&working, false); return }
            set(&working, logsFresh || Date().timeIntervalSince(lastActivity) <= 20)
        }
    }

    /// Assign only when the value actually changed.
    ///
    /// `@Published` fires on every assignment, equal or not, and each fire
    /// re-runs the whole panel's SwiftUI body. These pollers rewrite the same
    /// numbers every 2/4/32 seconds — almost always identical — so writing
    /// unconditionally meant re-laying out the dashboard for nothing.
    private func set<T: Equatable>(_ property: inout T, _ value: T) {
        guard property != value else { return }
        property = value
    }

    private nonisolated static func checkLogs(_ monitor: AgentActivityMonitor) async -> Bool {
        monitor.isActive(within: 20)
    }

    // Cheap: savings counters from the local usage DB.
    private func refreshFast() {
        Task {
            let s = await Self.loadSavings()
            set(&todaySaved, s.todaySaved)
            set(&totalSaved, s.totalSaved)
            set(&recent, s.recent)
            if lastQueryCount >= 0, s.queryCount > lastQueryCount { flash() }
            lastQueryCount = s.queryCount
            set(&queryCount, s.queryCount)
        }
    }

    // Heavier: AI token usage (parses session logs) + agent detection + per-file
    // token breakdown.
    private func refreshSlow(force: Bool = false) {
        Task {
            let a = await Self.loadAgentsAndUsage(force: force)
            set(&aiTokens, a.aiTokens)
            set(&agents, a.agents)
            set(&connected, a.connected)
            set(&projectUsage, a.projectUsage)
            set(&tokensByDay, a.tokensByDay)
            set(&week, a.week)
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

    struct Savings: Sendable {
        var todaySaved = 0, totalSaved = 0, queryCount = 0
        var recent: [UsageEvent] = []
    }
    struct AgentsUsage: Sendable {
        var aiTokens = 0
        var agents: [DetectedAgent] = []
        var connected = false
        var projectUsage: [ProjectAIUsage] = []
        var tokensByDay: [String: Int] = [:]
        var week = BuildSummary()
    }

    private nonisolated static func loadSavings() async -> Savings {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return Savings() }
        let s = store.summary()
        return Savings(todaySaved: store.todaySaved(), totalSaved: s.totalSaved,
                       queryCount: s.queryCount, recent: store.recentEvents(limit: 6))
    }

    private nonisolated static func loadAgentsAndUsage(force: Bool = false) async -> AgentsUsage {
        if force {
            AgentSessionReader.invalidate()
            BuildLogReader.invalidate()
            ProjectAITokenReader.invalidate()
        }
        // One transcript pass feeds the headline figure, the per-project cards,
        // the calendar, and the week strip; they used to walk ~/.claude/projects
        // independently.
        let usage = AgentSessionReader.snapshot(force: force)
        let week = BuildLogReader.log(
            since: TimeKeys.localStartOfDay(Date().timeIntervalSince1970 - 6 * 86_400),
            snapshot: usage).summary
        return AgentsUsage(aiTokens: usage.totalTokens,
                           agents: AgentDetector.detect(),
                           connected: ClaudeIntegration.isGloballyInstalled(),
                           projectUsage: ProjectAITokenReader.topProjects(snapshot: usage),
                           tokensByDay: usage.byDay,
                           week: week)
    }
}
