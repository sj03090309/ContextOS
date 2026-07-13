import ArgumentParser
import ContextOSCore
import Foundation

@main
struct ContextOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contextos",
        abstract: "Local, AI-free context manager for Claude Code.",
        version: "2.0.0",
        subcommands: [Connect.self, Context.self, Watch.self, Hook.self],
        defaultSubcommand: Connect.self
    )
}

// MARK: - contextos connect

/// One command to make every detected AI agent use ContextOS automatically.
struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up automatic use in every detected AI agent (Claude Code · Codex · Gemini · Cursor · Windsurf)."
    )

    func run() throws {
        let mcpPath = Self.binaryPath(name: "contextos-mcp")
        let cliPath = Self.binaryPath(name: "contextos")

        // Claude Code — the richest integration: memory file + `claude mcp add`
        // + an auto-inject prompt hook so ContextOS runs on *every* prompt,
        // not only when the agent chooses to call the MCP tools.
        print("── Claude Code ──")
        let url = ClaudeIntegration.globalMemoryURL()
        let updated = try ClaudeIntegration.installInstruction(at: url)
        print("\(updated ? "↻ 갱신" : "✓ 추가")됨: \(url.path)")
        if Self.registerViaClaudeCLI(mcpBinaryPath: mcpPath) {
            print("✓ MCP 서버 전역 등록 완료 (모든 프로젝트)")
        } else {
            print("MCP 서버를 전역 등록하려면 아래 한 줄을 터미널에 붙여넣으세요:")
            print("  \(ClaudeIntegration.mcpAddCommand(mcpBinaryPath: mcpPath))")
        }
        do {
            try ClaudeIntegration.installPromptHook(at: ClaudeIntegration.settingsURL(), contextosBinaryPath: cliPath)
            print("✓ 자동 주입 훅 설치 (매 프롬프트마다 관련 파일 자동 제공)")
        } catch {
            print("자동 주입 훅 설치 실패(수동 설정 가능): \(error)")
        }

        // Every other detected agent, each in its own config format.
        let others = AgentIntegration.connectAll(mcpBinaryPath: mcpPath)
        if !others.isEmpty {
            print("\n── 다른 AI 에이전트 ──")
            for r in others {
                var line = "✓ \(r.agent): MCP 등록 → \(r.mcpConfigPath)"
                if let inst = r.instructionPath { line += "\n    지침 설치 → \(inst)" }
                print(line)
            }
        }

        print("\n완료! 연결된 도구를 재시작하면 아무것도 안 해도 자동으로 토큰을 아낍니다.")
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

    /// Resolve a bundled binary (`contextos` or `contextos-mcp`) to a stable
    /// installed path, preferring an installed .app over the transient dev build.
    static func binaryPath(name: String) -> String {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let appLocations = [
            "/Applications/ContextOS.app",
            home.appendingPathComponent("Applications/ContextOS.app").path,
            home.appendingPathComponent("Desktop/ContextOS.app").path
        ]
        for app in appLocations {
            let path = app + "/Contents/Resources/" + name
            if fm.fileExists(atPath: path) { return path }
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let siblingDir = exe.deletingLastPathComponent()
        let sibling = siblingDir.appendingPathComponent(name).path
        if fm.fileExists(atPath: sibling), !siblingDir.path.contains("/debug") { return sibling }
        return fm.currentDirectoryPath + "/.build/release/" + name
    }
}

// MARK: - contextos hook

/// Claude Code `UserPromptSubmit` hook. Reads the prompt JSON on stdin, and
/// prints the relevant-files context as `additionalContext` so it's injected
/// into every prompt automatically. Always exits 0 (never blocks the prompt).
struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Claude Code prompt hook (reads stdin JSON, injects relevant context)."
    )

    func run() throws {
        guard let data = try? FileHandle.standardInput.readToEnd(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let prompt = (obj["prompt"] as? String) ?? ""
        let cwd = (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        // Skip trivial prompts (confirmations, one-word replies).
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 else { return }

        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        // Only index real project roots — never a home dir or huge folder the
        // agent happens to run in (this fires on *every* prompt).
        guard ContextService.looksLikeProjectRoot(root) else { return }
        let service = ContextService()
        guard let (selection, text) = try? service.promptContext(query: prompt, projectRoot: root),
              !selection.included.isEmpty else { return }
        service.recordUsage(for: selection, query: prompt, projectRoot: root)

        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "UserPromptSubmit",
                "additionalContext": text
            ]
        ]
        if let out = try? JSONSerialization.data(withJSONObject: payload) {
            FileHandle.standardOutput.write(out)
        }
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
