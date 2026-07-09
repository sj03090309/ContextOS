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

    init() { refresh() }

    func refresh() {
        Task {
            let m = await Self.load()
            todaySaved = m.todaySaved
            totalSaved = m.totalSaved
            queryCount = m.queryCount
            avgScore = m.avgScore
            aiTokens = m.aiTokens
            aiProjects = m.aiProjects
            agents = m.agents
            connected = m.connected
        }
    }

    struct Metrics: Sendable {
        var todaySaved = 0, totalSaved = 0, queryCount = 0, avgScore = 0
        var aiTokens = 0, aiProjects = 0
        var agents: [DetectedAgent] = []
        var connected = false
    }

    private nonisolated static func load() async -> Metrics {
        var m = Metrics()
        if let store = try? UsageStore(path: UsageStore.defaultURL().path) {
            let s = store.summary()
            m.todaySaved = store.todaySaved()
            m.totalSaved = s.totalSaved
            m.queryCount = s.queryCount
            m.avgScore = s.avgContextScore
        }
        let ai = ClaudeUsageReader.totalUsageAllProjects()
        m.aiTokens = ai.tokens
        m.aiProjects = ai.projects
        m.agents = AgentDetector.detect()
        m.connected = ClaudeIntegration.isGloballyInstalled()
        return m
    }
}
