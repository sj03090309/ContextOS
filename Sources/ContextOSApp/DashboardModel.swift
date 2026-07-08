import Foundation
import AppKit
import ContextOSCore

/// Drives the menu-bar dashboard. Heavy work (indexing + optimization) runs off
/// the main actor via `nonisolated` helpers so the UI never blocks.
@MainActor
final class DashboardModel: ObservableObject {

    @Published var projectPath: String
    @Published var query: String = ""
    @Published var budget: Int = 8000
    @Published var selection: ContextSelection?
    @Published var summary: ContextService.ProjectSummary?
    @Published var lint: [PromptLinter.Finding] = []
    @Published var advisories: [ContextAdvisor.Advisory] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var todaySaved = 0

    private let defaultsKey = "ContextOS.projectPath"

    init() {
        projectPath = UserDefaults.standard.string(forKey: defaultsKey)
            ?? FileManager.default.currentDirectoryPath
        Task { todaySaved = await Self.loadTodaySaved() }
    }

    var projectURL: URL? {
        projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath).standardizedFileURL
    }

    var projectName: String {
        projectURL?.lastPathComponent ?? "No project"
    }

    /// Tokens saved vs. sending the whole project, as (saved, percent).
    var savings: (saved: Int, percent: Int)? {
        guard let total = summary?.estimatedTotalTokens,
              let selected = selection?.estimatedTokens,
              total > 0 else { return nil }
        let saved = max(0, total - selected)
        return (saved, Int((Double(saved) / Double(total) * 100).rounded()))
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
        UserDefaults.standard.set(projectPath, forKey: defaultsKey)
        selection = nil
        Task { await refreshSummary() }
    }

    func runQuery() {
        guard let root = projectURL, !query.isEmpty else { return }
        lint = PromptLinter().lint(query)
        let q = query
        let b = budget
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let result = try await Self.optimize(query: q, root: root, budget: b)
                selection = result
                await refreshSummary()
                advisories = ContextAdvisor().advise(
                    selection: result,
                    fullProjectTokens: summary?.estimatedTotalTokens,
                    promptFindings: lint
                )
                todaySaved = await Self.recordAndTotal(
                    project: root, query: q, selection: result,
                    fullTokens: summary?.estimatedTotalTokens ?? result.estimatedTokens
                )
            } catch {
                errorMessage = "\(error)"
            }
            isWorking = false
        }
    }

    func refreshSummary() async {
        guard let root = projectURL else { return }
        summary = try? await Self.loadSummary(root: root)
    }

    // MARK: - Off-main-actor work

    private nonisolated static func optimize(query: String, root: URL, budget: Int) async throws -> ContextSelection {
        try ContextService().relevantContext(query: query, projectRoot: root, tokenBudget: budget)
    }

    private nonisolated static func loadSummary(root: URL) async throws -> ContextService.ProjectSummary {
        let service = ContextService()
        try service.ensureIndexed(projectRoot: root)
        return try service.summary(projectRoot: root)
    }

    private nonisolated static func recordAndTotal(
        project: URL, query: String, selection: ContextSelection, fullTokens: Int
    ) async -> Int {
        UsageStore.record(UsageEvent(
            project: project.path, query: query,
            selectedTokens: selection.estimatedTokens, fullTokens: fullTokens,
            contextScore: selection.contextScore, fileCount: selection.included.count
        ))
        return (try? UsageStore(path: UsageStore.defaultURL().path))?.todaySaved() ?? 0
    }

    private nonisolated static func loadTodaySaved() async -> Int {
        (try? UsageStore(path: UsageStore.defaultURL().path))?.todaySaved() ?? 0
    }
}
