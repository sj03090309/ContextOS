import ArgumentParser
import ContextOSCore
import Foundation

@main
struct ContextOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contextos",
        abstract: "Local, AI-free context manager for Claude Code.",
        version: "1.2.0",
        subcommands: [Index.self, Stats.self, Context.self, Lint.self, Git.self, Rules.self, Deps.self, Usage.self, Snapshot.self, Setup.self, Watch.self],
        defaultSubcommand: Index.self
    )
}

// MARK: - contextos watch

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch a project and re-index automatically when files change."
    )

    @Argument(help: "Project root to watch. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        setvbuf(stdout, nil, _IONBF, 0) // unbuffered so a long-running watcher prints live
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let service = ContextService()
        _ = try service.ensureIndexed(projectRoot: root)
        print("👀 감시 중: \(root.path)  (Ctrl+C로 종료)")

        let watcher = FileWatcher(paths: [root.path]) {
            if let stats = try? service.reindex(projectRoot: root) {
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("♻️  [\(ts)] 재인덱싱: 파일 \(stats.filesIndexed)개, 심볼 \(stats.symbolsIndexed)개")
            }
        }
        watcher.start()
        RunLoop.main.run() // keep the process alive
    }
}

// MARK: - contextos setup

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Auto-discover your local projects, index them, and detect AI agents."
    )

    @Option(name: [.long], help: "Extra folder to scan (repeatable).")
    var scan: [String] = []

    @Flag(name: [.long], help: "Only discover; don't index (faster).")
    var noIndex = false

    func run() throws {
        print("🔍 프로젝트를 탐색합니다…")
        var roots = ProjectRegistry.defaultScanRoots()
        roots.append(contentsOf: scan.map { URL(fileURLWithPath: $0) })
        let discovered = ProjectRegistry.discover(roots: roots)

        var registered = ProjectRegistry.list()
        for path in discovered where !registered.contains(path) { registered.append(path) }
        ProjectRegistry.save(registered)

        print("✓ 프로젝트 \(discovered.count)개 발견, 총 \(registered.count)개 등록됨")
        for path in discovered { print("  • \(URL(fileURLWithPath: path).lastPathComponent)  (\(path))") }

        if !noIndex {
            print("\n📚 인덱싱 중…")
            let service = ContextService()
            for path in registered {
                let root = URL(fileURLWithPath: path)
                if let stats = try? service.reindex(projectRoot: root) {
                    print("  ✓ \(root.lastPathComponent): 파일 \(stats.filesIndexed)개, 심볼 \(stats.symbolsIndexed)개")
                }
            }
        }

        let agents = AgentDetector.detect()
        print("\n🤖 감지된 AI 에이전트 (\(agents.count)개):")
        if agents.isEmpty {
            print("  (감지된 에이전트 없음)")
        } else {
            for a in agents {
                print("  • \(a.name)\(a.detail.map { " — \($0)" } ?? "")")
            }
        }

        // Real AI token usage per project (Claude Code local logs).
        let used = registered.compactMap { ClaudeUsageReader.usage(forProjectPath: $0) }
            .sorted { $0.totalTokens > $1.totalTokens }
        if !used.isEmpty {
            print("\n💰 AI 토큰 사용 이력이 있는 프로젝트:")
            for u in used {
                print("  • \(URL(fileURLWithPath: u.projectPath).lastPathComponent): \(TokenEstimator.abbrev(u.totalTokens)) 토큰 (세션 \(u.sessions)개)")
            }
        }

        print("\n완료! ContextOS 메뉴바 앱을 열면 AI 사용 프로젝트 카드가 보입니다.")
    }
}

// MARK: - contextos snapshot

struct Snapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save or restore a session snapshot (branch, changes, rules)."
    )

    @Option(name: [.long], help: "Project root. Defaults to the current directory.")
    var path: String = "."

    @Flag(name: [.long], help: "Capture and save the current state.")
    var save = false

    @Option(name: [.long], help: "Note to attach when saving.")
    var note: String?

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        if save {
            let snapshot = SessionSnapshotStore.capture(projectRoot: root, note: note)
            try SessionSnapshotStore.save(snapshot, projectRoot: root)
            print("✓ 스냅샷을 저장했습니다: \(SessionSnapshotStore.url(forProjectRoot: root).path)\n")
            print(snapshot.rendered())
        } else if let saved = SessionSnapshotStore.load(projectRoot: root) {
            print(saved.rendered())
        } else {
            print("저장된 스냅샷이 없습니다. 현재 상태:\n")
            print(SessionSnapshotStore.capture(projectRoot: root).rendered())
        }
    }
}

// MARK: - contextos usage

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show local usage analytics (tokens saved, per project)."
    )

    func run() throws {
        let store = try UsageStore(path: UsageStore.defaultURL().path)
        let s = store.summary()
        print("사용 통계 (전체 로컬)")
        print("  쿼리 수:        \(s.queryCount)회")
        print("  오늘 절약:      \(TokenEstimator.humanReadable(store.todaySaved()))")
        print("  누적 절약:      \(TokenEstimator.humanReadable(s.totalSaved))")
        print("  평균 컨텍스트:  \(TokenEstimator.humanReadable(s.avgSelectedTokens))")
        print("  평균 점수:      \(s.avgContextScore)/100")
        if !s.perProject.isEmpty {
            print("  프로젝트별 절약:")
            for p in s.perProject {
                let name = URL(fileURLWithPath: p.project).lastPathComponent
                print("    \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(TokenEstimator.humanReadable(p.saved))  (\(p.count)회)")
            }
        }
    }
}

// MARK: - contextos deps

struct Deps: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deps",
        abstract: "Explore the project's import/dependency graph."
    )

    @Option(name: [.long], help: "Project root. Defaults to the current directory.")
    var path: String = "."

    @Option(name: [.long], help: "Root file to start the tree from.")
    var root: String?

    @Flag(name: [.long], help: "Emit Graphviz DOT instead of a text tree.")
    var dot = false

    func run() throws {
        let projectRoot = URL(fileURLWithPath: path).standardizedFileURL
        try ContextService().ensureIndexed(projectRoot: projectRoot)
        let store = try Indexer.openStore(forProjectRoot: projectRoot)
        let graph = try DependencyGraph.build(from: store)

        if dot {
            print(graph.dot())
        } else {
            print("의존성 그래프 (\(graph.nodes.count) 노드, \(graph.edgeCount) 엣지):")
            print(graph.textTree(root: root))
        }
    }
}

// MARK: - contextos rules

struct Rules: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or set project rules that persist across Claude sessions."
    )

    @Option(name: [.long], help: "Project root. Defaults to the current directory.")
    var path: String = "."

    @Option(name: [.long], help: "Set the primary language, e.g. \"Python 3.12\".")
    var language: String?

    @Option(name: [.long], help: "Set the framework, e.g. \"FastAPI\".")
    var framework: String?

    @Option(name: [.long], help: "Set style conventions (comma-separated), e.g. \"PEP8,type hints\".")
    var style: String?

    @Option(name: [.long], help: "Add a freeform note (repeatable).")
    var note: [String] = []

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let isSetting = language != nil || framework != nil || style != nil || !note.isEmpty

        if isSetting {
            var rules = ProjectRulesStore.load(projectRoot: root) ?? ProjectRules()
            if let language { rules.language = language }
            if let framework { rules.framework = framework }
            if let style { rules.style = style.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if !note.isEmpty { rules.notes.append(contentsOf: note) }
            try ProjectRulesStore.save(rules, projectRoot: root)
            print("✓ 규칙을 저장했습니다: \(ProjectRulesStore.url(forProjectRoot: root).path)")
            print(rules.rendered())
        } else {
            let rules = ProjectRulesStore.effective(projectRoot: root)
            print("프로젝트 규칙:")
            print(rules.rendered())
        }
    }
}

// MARK: - contextos git

struct Git: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show the Git signals ContextOS uses (branch, commits, changed files)."
    )

    @Argument(help: "Project root. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let git = GitAnalyzer()
        guard git.isRepository(root) else {
            print("Git 저장소가 아닙니다: \(root.path)")
            return
        }
        print("브랜치:   \(git.currentBranch(root) ?? "-")")
        let commits = git.recentCommits(root, limit: 5)
        if !commits.isEmpty {
            print("최근 커밋:")
            for c in commits {
                print("  \(c.shortHash)  \(c.subject)  (\(c.relativeDate), \(c.author))")
            }
        }
        let changed = git.changedFiles(root).sorted()
        print("변경된 파일 (\(changed.count)개):")
        for p in changed.prefix(20) { print("  • \(p)") }
    }
}

// MARK: - contextos lint

struct Lint: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check a prompt for vague or over-broad requests (rule-based)."
    )

    @Argument(help: "The prompt to check.")
    var prompt: String

    func run() throws {
        let findings = PromptLinter().lint(prompt)
        guard !findings.isEmpty else {
            print("✓ 좋습니다 — 구체적이고 범위가 명확합니다.")
            return
        }
        for f in findings {
            let mark = f.severity == .warning ? "⚠" : "ℹ"
            print("\(mark) [\(f.rule)] \(f.message)")
            print("    → \(f.suggestion)")
        }
    }
}

// MARK: - contextos context

struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Select the most relevant files for a query, within a token budget."
    )

    @Argument(help: "What you want to work on, e.g. \"fix login\".")
    var query: String

    @Option(name: [.short, .long], help: "Token budget for the context.")
    var budget: Int = 8000

    @Option(name: [.long], help: "Project root. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        // Auto-indexes if needed and folds in Git recency signals.
        let service = ContextService()
        let selection = try service.relevantContext(
            query: query, projectRoot: root, tokenBudget: budget
        )
        service.recordUsage(for: selection, query: query, projectRoot: root)

        guard !selection.isEmpty else {
            print("“\(query)”와 관련된 파일을 찾지 못했습니다.")
            print("검색어: \(selection.terms.joined(separator: ", "))")
            return
        }

        print("쿼리:     \(query)")
        if let r = selection.refinement, r.changed {
            print("이해:     \(r.explanation)")
        }
        print("검색어:   \(selection.terms.joined(separator: ", "))")
        print("예산:     \(TokenEstimator.humanReadable(selection.tokenBudget))")
        print("컨텍스트 점수: \(selection.contextScore)/100")
        print("")
        print("포함됨 (\(selection.included.count)개 파일, \(TokenEstimator.humanReadable(selection.estimatedTokens))):")
        for file in selection.included {
            print("  • \(file.path)  [\(TokenEstimator.humanReadable(file.estimatedTokens)), 점수 \(file.score)]")
            if let reason = file.reasons.first {
                let extra = file.reasons.count > 1 ? " (외 \(file.reasons.count - 1)개)" : ""
                print("      \(reason)\(extra)")
            }
        }
        if !selection.excluded.isEmpty {
            print("")
            print("제외됨 — 관련은 있으나 예산 초과 (\(selection.excluded.count)개):")
            for file in selection.excluded.prefix(8) {
                print("  · \(file.path)  [\(TokenEstimator.humanReadable(file.estimatedTokens)), 점수 \(file.score)]")
            }
        }

        let full = try? service.summary(projectRoot: root).estimatedTotalTokens
        let advisories = ContextAdvisor().advise(
            selection: selection,
            fullProjectTokens: full,
            promptFindings: PromptLinter().lint(query)
        )
        if !advisories.isEmpty {
            print("")
            for a in advisories {
                print("\(a.severity == .warning ? "⚠" : "ℹ") \(a.message)")
            }
        }
    }
}

// MARK: - contextos index

struct Index: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan a project and build its index."
    )

    @Argument(help: "Project root to index. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard directoryExists(root) else {
            throw ValidationError("디렉토리가 아닙니다: \(root.path)")
        }

        FileHandle.standardError.write(Data("인덱싱 중: \(root.path) …\n".utf8))

        let indexer = Indexer()
        let stats = try indexer.index(projectRoot: root)

        print("✓ \(format(stats.duration)) 만에 인덱싱 완료")
        print("  파일:     \(stats.filesIndexed)개  (건너뜀 \(stats.filesSkipped)개)")
        print("  심볼:     \(stats.symbolsIndexed)개")
        print("  import:   \(stats.importsIndexed)개")
        if !stats.byLanguage.isEmpty {
            print("  언어별:")
            for (lang, count) in stats.byLanguage.sorted(by: { $0.value > $1.value }) {
                print("    \(lang.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(count)")
            }
        }
        let dbURL = Indexer.databaseURL(forProjectRoot: root)
        print("  인덱스:   \(dbURL.path)")
    }
}

// MARK: - contextos stats

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show stats for an existing index."
    )

    @Argument(help: "Project root. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let dbURL = Indexer.databaseURL(forProjectRoot: root)
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw ValidationError("인덱스를 찾을 수 없습니다. 먼저 `contextos index \(path)` 를 실행하세요.")
        }

        let store = try Indexer.openStore(forProjectRoot: root)
        print("\(root.path) 인덱스")
        print("  파일:     \(try store.fileCount())개")
        print("  심볼:     \(try store.symbolCount())개")
        print("  import:   \(try store.importCount())개")

        let byLang = try store.fileCountByLanguage()
        if !byLang.isEmpty {
            print("  언어별:")
            for (lang, count) in byLang.sorted(by: { $0.value > $1.value }) {
                print("    \(lang.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(count)")
            }
        }
    }
}

// MARK: - Helpers

private func directoryExists(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return exists && isDir.boolValue
}

private func format(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
    return String(format: "%.2f s", seconds)
}
