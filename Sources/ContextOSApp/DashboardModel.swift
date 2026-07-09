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
    /// Brief highlight when MCP just handled an optimization.
    @Published var flashing = false

    private var lastQueryCount = -1
    private var timer: Timer?
    private var tick = 0

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
            if lastQueryCount >= 0, s.queryCount > lastQueryCount { flash() }
            lastQueryCount = s.queryCount
            queryCount = s.queryCount
        }
    }

    // Heavier: AI token usage (parses session logs) + agent detection.
    private func refreshSlow() {
        Task {
            let a = await Self.loadAgentsAndUsage()
            aiTokens = a.aiTokens
            aiProjects = a.aiProjects
            agents = a.agents
            connected = a.connected
        }
    }

    private func flash() {
        flashing = true
        Task { try? await Task.sleep(nanoseconds: 800_000_000); flashing = false }
    }

    struct Savings: Sendable { var todaySaved = 0, totalSaved = 0, queryCount = 0, avgScore = 0 }
    struct AgentsUsage: Sendable {
        var aiTokens = 0, aiProjects = 0
        var agents: [DetectedAgent] = []
        var connected = false
    }

    private nonisolated static func loadSavings() async -> Savings {
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else { return Savings() }
        let s = store.summary()
        return Savings(todaySaved: store.todaySaved(), totalSaved: s.totalSaved,
                       queryCount: s.queryCount, avgScore: s.avgContextScore)
    }

    private nonisolated static func loadAgentsAndUsage() async -> AgentsUsage {
        let ai = ClaudeUsageReader.totalUsageAllProjects()
        return AgentsUsage(aiTokens: ai.tokens, aiProjects: ai.projects,
                           agents: AgentDetector.detect(),
                           connected: ClaudeIntegration.isGloballyInstalled())
    }
}
