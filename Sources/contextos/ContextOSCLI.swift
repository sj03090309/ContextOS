import ArgumentParser
import ContextOSCore
import Foundation

@main
struct ContextOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contextos",
        abstract: "Local, AI-free context manager for Claude Code.",
        version: "2.0.0",
        subcommands: [Connect.self, Context.self, Watch.self],
        defaultSubcommand: Connect.self
    )
}

// MARK: - contextos connect

/// One command to make Claude Code use ContextOS automatically, everywhere.
struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up automatic use in Claude Code (CLAUDE.md instruction + MCP registration)."
    )

    func run() throws {
        let mcpPath = Self.mcpBinaryPath()

        let url = ClaudeIntegration.globalMemoryURL()
        let updated = try ClaudeIntegration.installInstruction(at: url)
        print("\(updated ? "↻ 갱신" : "✓ 추가")됨: \(url.path)")
        print("  → 이제 모든 Claude Code 세션이 파일 탐색 전에 ContextOS를 먼저 사용합니다.\n")

        if Self.registerViaClaudeCLI(mcpBinaryPath: mcpPath) {
            print("✓ MCP 서버 전역 등록 완료 (모든 프로젝트)")
        } else {
            print("MCP 서버를 전역 등록하려면 아래 한 줄을 터미널에 붙여넣으세요:")
            print("  \(ClaudeIntegration.mcpAddCommand(mcpBinaryPath: mcpPath))")
        }
        print("\n완료! Claude Code를 재시작하면 아무것도 안 해도 자동으로 토큰을 아낍니다.")
    }

    private static func registerViaClaudeCLI(mcpBinaryPath: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "mcp", "add", "--scope", "user", "contextos", "--", mcpBinaryPath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Prefer a stable installed location over the (transient) dev build.
    private static func mcpBinaryPath() -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appLocations = [
            "/Applications/ContextOS.app",
            home.appendingPathComponent("Applications/ContextOS.app").path,
            home.appendingPathComponent("Desktop/ContextOS.app").path
        ]
        for app in appLocations {
            let path = app + "/Contents/Resources/contextos-mcp"
            if fm.fileExists(atPath: path) { return path }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let siblingDir = exe.deletingLastPathComponent()
        let sibling = siblingDir.appendingPathComponent("contextos-mcp").path
        if fm.fileExists(atPath: sibling), !siblingDir.path.contains("/debug") { return sibling }
        return fm.currentDirectoryPath + "/.build/release/contextos-mcp"
    }
}

// MARK: - contextos context

/// Manual path: pick the relevant files for a query (for pasting into any AI).
struct Context: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find the most relevant files for a task (auto-indexes the project)."
    )

    @Argument(help: "What you want to work on, e.g. \"fix login\".")
    var query: String

    @Option(name: [.short, .long], help: "Token budget for the context.")
    var budget: Int = 8000

    @Option(name: [.long], help: "Project root. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let selection = try ContextService().relevantContext(
            query: query, projectRoot: root, tokenBudget: budget
        )

        guard !selection.isEmpty else {
            print("‘\(query)’ 와 관련된 파일을 찾지 못했어요.")
            return
        }

        print("요청:     \(query)")
        if let r = selection.refinement, r.changed {
            print("이해:     \(r.explanation)")
        }
        print("정확도:   \(selection.contextScore)/100")
        print("고른 파일 (\(selection.included.count)개, \(TokenEstimator.humanReadable(selection.estimatedTokens))):")
        for file in selection.included {
            print("  • \(file.path)  [\(TokenEstimator.humanReadable(file.estimatedTokens))]")
            if let reason = file.reasons.first { print("      \(reason)") }
        }
    }
}

// MARK: - contextos watch

/// Keep a project's index fresh automatically as files change.
struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch a project and re-index automatically when files change."
    )

    @Argument(help: "Project root to watch. Defaults to the current directory.")
    var path: String = "."

    func run() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let root = URL(fileURLWithPath: path).standardizedFileURL
        let service = ContextService()
        _ = try service.ensureIndexed(projectRoot: root)
        print("👀 감시 중: \(root.path)  (Ctrl+C로 종료)")

        let watcher = FileWatcher(paths: [root.path]) {
            if let stats = try? service.reindex(projectRoot: root) {
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("♻️  [\(ts)] 다시 읽음: 파일 \(stats.filesIndexed)개")
            }
        }
        watcher.start()
        RunLoop.main.run()
    }
}
