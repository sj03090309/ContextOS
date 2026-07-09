import Foundation
import AppKit
import ContextOSCore

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
}

/// Drives the small menu-bar panel. Heavy work runs off the main actor.
@MainActor
final class DashboardModel: ObservableObject {

    @Published var projectPath: String
    @Published var query: String = ""
    @Published var budgetPreset: BudgetPreset = .normal
    @Published var selection: ContextSelection?
    @Published var bundle: String = ""
    @Published var summary: ContextService.ProjectSummary?
    @Published var copied = false
    @Published var isWorking = false
    @Published var errorMessage: String?

    // Proactive context from files you're currently editing.
    @Published var proactiveFiles: [String] = []
    @Published var proactiveBundle: String = ""
    @Published var proactiveCopied = false

    private let defaultsKey = "ContextOS.projectPath"
    private var watcher: FileWatcher?

    init() {
        projectPath = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        refresh()
        startWatching()
    }

    var projectURL: URL? {
        projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath).standardizedFileURL
    }
    var projectName: String { projectURL?.lastPathComponent ?? "" }
    var budget: Int { budgetPreset.tokens }

    /// Tokens saved vs. sending the whole project, as a percentage.
    var savedPercent: Int? {
        guard let total = summary?.estimatedTotalTokens,
              let selected = selection?.estimatedTokens, total > 0 else { return nil }
        return Int((Double(max(0, total - selected)) / Double(total) * 100).rounded())
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "폴더 선택"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectPath = url.path
        UserDefaults.standard.set(projectPath, forKey: defaultsKey)
        selection = nil
        startWatching()
        refresh()
    }

    func runQuery() {
        guard let root = projectURL, !query.isEmpty else { return }
        let q = query, b = budget
        isWorking = true
        errorMessage = nil
        copied = false
        Task {
            do {
                let (result, text) = try await Self.optimize(query: q, root: root, budget: b)
                selection = result
                bundle = text
                summary = try? await Self.loadSummary(root: root)
            } catch {
                errorMessage = "\(error)"
            }
            isWorking = false
        }
    }

    func copyBundle() {
        guard !bundle.isEmpty else { return }
        let task = query.trimmingCharacters(in: .whitespacesAndNewlines)
        copy("다음은 '\(task)' 작업에 필요한 코드입니다. 이 코드를 바탕으로 도와주세요.\n\n" + bundle)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); copied = false }
    }

    func copyProactive() {
        guard !proactiveBundle.isEmpty else { return }
        copy("지금 작업 중인 코드입니다. 이걸 바탕으로 도와주세요.\n\n" + proactiveBundle)
        proactiveCopied = true
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); proactiveCopied = false }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func refresh() {
        Task {
            summary = try? await Self.loadSummary(root: projectURL)
            let p = await Self.loadProactive(root: projectURL)
            proactiveFiles = p.files
            proactiveBundle = p.bundle
        }
    }

    // MARK: - Auto re-index

    func startWatching() {
        watcher?.stop(); watcher = nil
        guard let root = projectURL else { return }
        let w = FileWatcher(paths: [root.path]) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        w.start()
        watcher = w
    }

    // MARK: - Off-main-actor work

    struct Proactive: Sendable { var files: [String]; var bundle: String }

    private nonisolated static func optimize(query: String, root: URL, budget: Int) async throws -> (ContextSelection, String) {
        try ContextService().optimizedBundle(query: query, projectRoot: root, tokenBudget: budget)
    }

    private nonisolated static func loadSummary(root: URL?) async -> ContextService.ProjectSummary? {
        guard let root else { return nil }
        let service = ContextService()
        guard (try? service.ensureIndexed(projectRoot: root)) != nil else { return nil }
        return try? service.summary(projectRoot: root)
    }

    private nonisolated static func loadProactive(root: URL?) async -> Proactive {
        guard let root, let (sel, bundle) = try? ContextService().proactiveContext(projectRoot: root) else {
            return Proactive(files: [], bundle: "")
        }
        return Proactive(files: sel.included.map(\.path), bundle: bundle)
    }
}
