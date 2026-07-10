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
    @Published var avgScore = 0
    @Published var aiTokens = 0
    @Published var aiProjects = 0
    @Published var agents: [DetectedAgent] = []
    @Published var connected = false
    /// Token usage grouped by project, broken down per AI agent.
    @Published var projectUsage: [ProjectAIUsage] = []
    /// Tokens saved per day for the last 7 days (oldest → today).
    @Published var daily: [DayPoint] = []
    /// Most recent optimization events, newest first.
    @Published var recent: [UsageEvent] = []
    /// Brief highlight when MCP just handled an optimization.
    @Published var flashing = false

    private var lastQueryCount = -1
    private var timer: Timer?
    private var tick = 0
    private var flashTask: Task<Void, Never>?

    init() {
        refreshFast()
        refreshSlow()
        // The savings counter (cheap SQLite) polls every 4s; the heavier AI-usage
        // + agent scan runs every ~32s.
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    /// Manual refresh (e.g. from the ↻ button): do everything now.
    func refresh() { refreshFast(); refreshSlow() }

    private func onTick() {
        tick += 1
        refreshFast()
        if tick % 8 == 0 { refreshSlow() }
    }

    // Cheap: savings counters from the local usage DB.
    private func refreshFast() {
        Task {
            let s = await Self.loadSavings()
            todaySaved = s.todaySaved
            totalSaved = s.totalSaved
            avgScore = s.avgScore
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
            aiProjects = a.aiProjects
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
        var todaySaved = 0, totalSaved = 0, queryCount = 0, avgScore = 0
        var daily: [DayPoint] = []
        var recent: [UsageEvent] = []
    }
    struct AgentsUsage: Sendable {
        var aiTokens = 0, aiProjects = 0
        var agents: [DetectedAgent] = []
        var connected = false
        var projectUsage: [ProjectAIUsage] = []
    }

    private nonisolated static func loadSavings() async -> Savings {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return Savings() }
        let s = store.summary()

        let parser = DateFormatter()
        parser.locale = Locale(identifier: "ko_KR")
        parser.dateFormat = "yyyy-MM-dd"
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "ko_KR")
        weekday.dateFormat = "EEEEE"     // narrow: 월/화/수/목/금/토/일
        let todayKey = parser.string(from: Date())
        let daily = store.dailySaved(days: 7).map { point in
            DayPoint(day: point.day, saved: point.saved,
                     label: parser.date(from: point.day).map { weekday.string(from: $0) } ?? "",
                     isToday: point.day == todayKey)
        }

        return Savings(todaySaved: store.todaySaved(), totalSaved: s.totalSaved,
                       queryCount: s.queryCount, avgScore: s.avgContextScore, daily: daily,
                       recent: store.recentEvents(limit: 6))
    }

    private nonisolated static func loadAgentsAndUsage() async -> AgentsUsage {
        let ai = ClaudeUsageReader.totalUsageAllProjects()
        return AgentsUsage(aiTokens: ai.tokens, aiProjects: ai.projects,
                           agents: AgentDetector.detect(),
                           connected: ClaudeIntegration.isGloballyInstalled(),
                           projectUsage: ProjectAITokenReader.topProjects())
    }
}
