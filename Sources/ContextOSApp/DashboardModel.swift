import Foundation
import AppKit
import ContextOSCore

/// Top-level split: the core optimizer vs. supporting insights.
enum DashMode: String, CaseIterable, Identifiable {
    case optimize = "최적화"
    case insights = "인사이트"
    var id: String { rawValue }
    var icon: String { self == .optimize ? "wand.and.stars" : "chart.bar.doc.horizontal" }
}

/// Sub-tabs under the "인사이트" mode (all ancillary to the core feature).
enum InsightTab: String, CaseIterable, Identifiable {
    case usage = "사용량"
    case agents = "에이전트"
    case project = "프로젝트"
    case deps = "의존성"
    var id: String { rawValue }
}

/// Plain-language length presets instead of a raw token number.
enum BudgetPreset: String, CaseIterable, Identifiable {
    case short = "짧게"
    case normal = "보통"
    case detailed = "자세히"
    var id: String { rawValue }
    var tokens: Int {
        switch self {
        case .short: return 4000
        case .normal: return 8000
        case .detailed: return 20000
        }
    }
    var hint: String {
        switch self {
        case .short: return "핵심만"
        case .normal: return "적당히"
        case .detailed: return "넉넉히"
        }
    }
}

/// Drives the dashboard. Heavy work (indexing/optimization/analytics) runs off
/// the main actor via `nonisolated` helpers so the UI never blocks.
@MainActor
final class DashboardModel: ObservableObject {

    @Published var projectPath: String
    @Published var query: String = ""
    @Published var budgetPreset: BudgetPreset = .normal
    /// The optimized, ready-to-paste context bundle (sliced file contents).
    @Published var bundle: String = ""
    @Published var copied = false
    @Published var selection: ContextSelection?

    var budget: Int { budgetPreset.tokens }
    @Published var summary: ContextService.ProjectSummary?
    @Published var lint: [PromptLinter.Finding] = []
    @Published var advisories: [ContextAdvisor.Advisory] = []
    /// Symbol names from the active project's index, for query autocomplete.
    @Published var symbolPool: [String] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var mode: DashMode = .optimize
    @Published var insightTab: InsightTab = .usage

    // Proactive context (from files you're currently editing)
    @Published var proactiveFiles: [String] = []
    @Published var proactiveBundle: String = ""
    @Published var proactiveCopied = false

    // Analytics
    @Published var todaySaved = 0
    @Published var usage: UsageSummary?
    @Published var recent: [UsageEvent] = []
    @Published var daily: [DayPoint] = []

    // Dependencies
    @Published var depsNodes = 0
    @Published var depsEdges = 0
    @Published var depsTree = ""

    // All tracked projects (multi-project overview) + detected AI agents.
    @Published var projects: [ProjectInfo] = []
    @Published var agents: [DetectedAgent] = []
    /// When true, only show projects that have real AI-agent token history.
    @Published var showOnlyAIProjects = true

    private let defaultsKey = "ContextOS.projectPath"
    /// Auto re-indexes the active project when its files change.
    private var watcher: FileWatcher?
    @Published var autoRefreshedAt: Date?

    init() {
        projectPath = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        refreshAll()
        startWatching()
    }

    /// Watch the active project and re-index automatically on file changes.
    func startWatching() {
        watcher?.stop()
        watcher = nil
        guard let root = projectURL else { return }
        let w = FileWatcher(paths: [root.path]) { [weak self] in
            Task { @MainActor in await self?.autoReindex() }
        }
        w.start()
        watcher = w
    }

    private func autoReindex() async {
        guard let root = projectURL else { return }
        await Self.reindex(root: root)
        await refreshSummary()
        symbolPool = await Self.loadSymbolPool(root: root)
        autoRefreshedAt = Date()
    }

    private nonisolated static func reindex(root: URL) async {
        _ = try? ContextService().reindex(projectRoot: root)
    }

    var hasProjects: Bool { !projects.isEmpty }

    /// Projects that have real AI-agent token usage.
    var aiProjects: [ProjectInfo] { projects.filter(\.hasAgentHistory) }
    /// Projects to actually show, honoring the AI-only filter.
    var visibleProjects: [ProjectInfo] { showOnlyAIProjects ? aiProjects : projects }
    /// Total AI tokens across all projects with history.
    var totalAITokens: Int { projects.reduce(0) { $0 + $1.aiTokens } }

    /// Autocomplete suggestions for the last token being typed in the query.
    var suggestions: [String] {
        let token = query.split(whereSeparator: { $0 == " " }).last.map(String.init) ?? ""
        let needle = token.lowercased()
        guard needle.count >= 2, !symbolPool.isEmpty else { return [] }
        // Rank: prefix match first, then substring; skip exact-already-typed.
        let prefix = symbolPool.filter { $0.lowercased().hasPrefix(needle) && $0.lowercased() != needle }
        let contains = symbolPool.filter { !$0.lowercased().hasPrefix(needle) && $0.lowercased().contains(needle) }
        var seen = Set<String>()
        return (prefix + contains).filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }

    /// Replace the last typed token with a chosen suggestion.
    func applySuggestion(_ symbol: String) {
        var parts = query.split(separator: " ").map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        parts.append(symbol)
        query = parts.joined(separator: " ") + " "
    }

    /// Add a project via a folder picker.
    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "프로젝트 추가"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectRegistry.add(url.path)
        projectPath = url.path
        UserDefaults.standard.set(projectPath, forKey: defaultsKey)
        refreshAll()
    }

    func removeProject(_ path: String) {
        let remaining = ProjectRegistry.remove(path)
        if projectPath == path {
            projectPath = remaining.first ?? ""
            UserDefaults.standard.set(projectPath, forKey: defaultsKey)
            selection = nil
            startWatching()
        }
        refreshAll()
    }

    /// Make a project the active one for querying.
    func selectProject(_ path: String) {
        projectPath = path
        UserDefaults.standard.set(path, forKey: defaultsKey)
        selection = nil
        startWatching()
        Task { await refreshSummary(); await reloadDeps() }
    }

    var projectURL: URL? {
        projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath).standardizedFileURL
    }

    var projectName: String { projectURL?.lastPathComponent ?? "프로젝트 없음" }

    var timeString: String {
        let f = DateFormatter(); f.dateFormat = "a h:mm"; f.locale = Locale(identifier: "ko_KR")
        return f.string(from: Date())
    }

    /// Tokens saved vs. sending the whole project, as (saved, percent).
    var savings: (saved: Int, percent: Int)? {
        guard let total = summary?.estimatedTotalTokens,
              let selected = selection?.estimatedTokens, total > 0 else { return nil }
        let saved = max(0, total - selected)
        return (saved, Int((Double(saved) / Double(total) * 100).rounded()))
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "프로젝트 선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
        UserDefaults.standard.set(projectPath, forKey: defaultsKey)
        selection = nil
        refreshAll()
    }

    /// Clickable starter queries derived from the project's most common symbols,
    /// so a newcomer isn't staring at a blank box.
    var exampleQueries: [String] { Array(symbolPool.prefix(5)) }

    /// Copy the optimized context (with the task line) to the clipboard, ready to
    /// paste into any AI chat.
    func copyBundle() {
        guard !bundle.isEmpty else { return }
        let task = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = "다음은 '\(task)' 작업에 필요한 코드입니다. 이 코드를 바탕으로 도와주세요.\n\n" + bundle
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
    }

    func runExample(_ q: String) {
        query = q
        runQuery()
    }

    func runQuery() {
        guard let root = projectURL, !query.isEmpty else { return }
        lint = PromptLinter().lint(query)
        let q = query, b = budget
        isWorking = true
        errorMessage = nil
        copied = false
        Task {
            do {
                let (result, bundleText) = try await Self.optimizeBundle(query: q, root: root, budget: b)
                selection = result
                bundle = bundleText
                await refreshSummary()
                advisories = ContextAdvisor().advise(
                    selection: result,
                    fullProjectTokens: summary?.estimatedTotalTokens,
                    promptFindings: lint
                )
                _ = await Self.record(
                    project: root, query: q, selection: result,
                    fullTokens: summary?.estimatedTotalTokens ?? result.estimatedTokens
                )
                await reloadAnalytics()
            } catch {
                errorMessage = "\(error)"
            }
            isWorking = false
        }
    }

    /// Reload everything: projects, project summary, analytics, dependency graph.
    func refreshAll() {
        Task {
            agents = await Self.loadAgents()
            projects = await Self.loadProjects(paths: ProjectRegistry.list())
            await refreshSummary()
            await reloadAnalytics()
            await reloadDeps()
        }
    }

    func refreshSummary() async {
        guard let root = projectURL else { return }
        summary = try? await Self.loadSummary(root: root)
        symbolPool = await Self.loadSymbolPool(root: root)
        await reloadProactive()
    }

    func reloadProactive() async {
        guard let root = projectURL else { proactiveFiles = []; proactiveBundle = ""; return }
        let r = await Self.computeProactive(root: root)
        proactiveFiles = r.files
        proactiveBundle = r.bundle
    }

    /// Copy the "currently editing" context, ready to paste into any AI chat.
    func copyProactive() {
        guard !proactiveBundle.isEmpty else { return }
        let text = "지금 작업 중인 코드입니다. 이걸 바탕으로 도와주세요.\n\n" + proactiveBundle
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        proactiveCopied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); proactiveCopied = false }
    }

    func reloadAnalytics() async {
        let bundle = await Self.loadAnalytics()
        usage = bundle.summary
        recent = bundle.recent
        daily = bundle.daily
        todaySaved = bundle.today
    }

    func reloadDeps() async {
        guard let root = projectURL else { return }
        let d = await Self.loadDeps(root: root)
        depsNodes = d.nodes
        depsEdges = d.edges
        depsTree = d.tree
    }

    // MARK: - Off-main-actor work

    struct AnalyticsBundle: Sendable {
        var summary: UsageSummary
        var recent: [UsageEvent]
        var daily: [DayPoint]
        var today: Int
    }

    struct DepsBundle: Sendable { var nodes: Int; var edges: Int; var tree: String }

    private nonisolated static func optimizeBundle(query: String, root: URL, budget: Int) async throws -> (ContextSelection, String) {
        try ContextService().optimizedBundle(query: query, projectRoot: root, tokenBudget: budget)
    }

    private nonisolated static func loadSummary(root: URL) async throws -> ContextService.ProjectSummary {
        let service = ContextService()
        try service.ensureIndexed(projectRoot: root)
        return try service.summary(projectRoot: root)
    }

    private nonisolated static func record(
        project: URL, query: String, selection: ContextSelection, fullTokens: Int
    ) async -> Int {
        UsageStore.record(UsageEvent(
            project: project.path, query: query,
            selectedTokens: selection.estimatedTokens, fullTokens: fullTokens,
            contextScore: selection.contextScore, fileCount: selection.included.count
        ))
        return 0
    }

    private nonisolated static func loadAnalytics() async -> AnalyticsBundle {
        let empty = UsageSummary(queryCount: 0, totalSaved: 0, avgSelectedTokens: 0, avgContextScore: 0, perProject: [])
        guard let store = try? UsageStore(path: UsageStore.defaultURL().path) else {
            return AnalyticsBundle(summary: empty, recent: [], daily: [], today: 0)
        }
        let daily = store.dailySaved(days: 7).map { DayPoint(day: $0.day, saved: $0.saved) }
        return AnalyticsBundle(summary: store.summary(), recent: store.recentEvents(), daily: daily, today: store.todaySaved())
    }

    /// Build the multi-project overview. Reads each project's existing index +
    /// its usage totals; does not force a (slow) reindex here.
    private nonisolated static func loadProjects(paths: [String]) async -> [ProjectInfo] {
        let usage = try? UsageStore(path: UsageStore.defaultURL().path)
        let perProject = usage?.summary().perProject ?? []
        let agentUsageByPath = await AgentCatUsageReader.projectUsage()
        let hiddenProjects = Set(ProjectRegistry.hiddenList())
        var savedByPath: [String: Int] = [:]
        var countByPath: [String: Int] = [:]
        for p in perProject { savedByPath[p.project] = p.saved; countByPath[p.project] = p.count }

        // Union of explicitly-added projects and any that have usage history.
        var seenPaths = Set<String>()
        var allPaths: [String] = []
        func appendPath(_ path: String) {
            guard !hiddenProjects.contains(path), seenPaths.insert(path).inserted else { return }
            allPaths.append(path)
        }
        paths.forEach(appendPath)
        perProject.map(\.project).forEach(appendPath)
        agentUsageByPath.keys.forEach(appendPath)

        var infos: [ProjectInfo] = []
        for path in allPaths {
            let root = URL(fileURLWithPath: path)
            var files = 0, symbols = 0, total = 0
            var indexed = false
            if FileManager.default.fileExists(atPath: Indexer.databaseURL(forProjectRoot: root).path),
               let store = try? Indexer.openStore(forProjectRoot: root) {
                indexed = true
                files = (try? store.fileCount()) ?? 0
                symbols = (try? store.symbolCount()) ?? 0
                total = ((try? store.allFiles()) ?? []).reduce(0) {
                    $0 + TokenEstimator().estimate(characterCount: $1.byteSize, language: $1.language)
                }
            }
            let daily = (usage?.dailySaved(project: path, days: 7) ?? []).map { DayPoint(day: $0.day, saved: $0.saved) }
            var agentUsages = (agentUsageByPath[path] ?? []).map {
                AgentUsage(provider: $0.provider, displayName: $0.displayName, tokens: $0.tokens)
            }
            let ai = agentUsages.isEmpty ? ClaudeUsageReader.usage(forProjectPath: path) : nil
            if let ai {
                agentUsages = [AgentUsage(provider: "claude", displayName: "Claude", tokens: ai.totalTokens)]
            }
            infos.append(ProjectInfo(
                path: path, files: files, symbols: symbols, totalTokens: total,
                savedTokens: savedByPath[path] ?? 0, queryCount: countByPath[path] ?? 0,
                daily: daily, isIndexed: indexed,
                aiTokens: agentUsages.reduce(0) { $0 + $1.tokens },
                aiSessions: ai?.sessions ?? 0,
                agentUsages: agentUsages
            ))
        }
        // AI-used projects first, by real token usage.
        return infos.sorted { ($0.aiTokens, $0.savedTokens) > ($1.aiTokens, $1.savedTokens) }
    }

    private nonisolated static func loadAgents() async -> [DetectedAgent] {
        AgentDetector.detect()
    }

    struct ProactiveResult: Sendable { var files: [String]; var bundle: String }

    private nonisolated static func computeProactive(root: URL) async -> ProactiveResult {
        guard let (sel, bundle) = try? ContextService().proactiveContext(projectRoot: root) else {
            return ProactiveResult(files: [], bundle: "")
        }
        return ProactiveResult(files: sel.included.map(\.path), bundle: bundle)
    }

    private nonisolated static func loadSymbolPool(root: URL) async -> [String] {
        guard FileManager.default.fileExists(atPath: Indexer.databaseURL(forProjectRoot: root).path),
              let store = try? Indexer.openStore(forProjectRoot: root) else { return [] }
        return (try? store.symbolNames()) ?? []
    }

    private nonisolated static func loadDeps(root: URL) async -> DepsBundle {
        let service = ContextService()
        _ = try? service.ensureIndexed(projectRoot: root)
        guard let store = try? Indexer.openStore(forProjectRoot: root),
              let graph = try? DependencyGraph.build(from: store) else {
            return DepsBundle(nodes: 0, edges: 0, tree: "")
        }
        return DepsBundle(nodes: graph.nodes.count, edges: graph.edgeCount, tree: graph.textTree())
    }
}

/// One day of savings, for the trend chart.
struct DayPoint: Identifiable, Sendable {
    var day: String
    var saved: Int
    var id: String { day }
}

/// A tracked project shown as a card in the multi-project overview.
struct ProjectInfo: Identifiable, Sendable {
    var path: String
    var files: Int
    var symbols: Int
    var totalTokens: Int
    var savedTokens: Int
    var queryCount: Int
    var daily: [DayPoint]
    var isIndexed: Bool
    // Real AI-agent (Claude Code) token usage read from local session logs.
    var aiTokens: Int
    var aiSessions: Int
    var agentUsages: [AgentUsage]
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    /// Whether an AI agent has actually been used on this project.
    var hasAgentHistory: Bool { aiTokens > 0 }
}

struct AgentUsage: Identifiable, Sendable {
    var provider: String
    var displayName: String
    var tokens: Int
    var id: String { provider }
}
