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

/// Claude Code hook. On `UserPromptSubmit` it (a) signals the menu-bar mascot to
/// start eating this instant and (b) injects the relevant-files context; on
/// `Stop` it signals the mascot to stop. Always exits 0 (never blocks the turn).
struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Claude Code hook (reads stdin JSON; injects context + drives the mascot in real time)."
    )

    func run() throws {
        guard let data = try? FileHandle.standardInput.readToEnd(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let event = (obj["hook_event_name"] as? String) ?? "UserPromptSubmit"

        // Real-time mascot control: the turn just ended → stop eating now.
        if event == "Stop" {
            Self.post(UsageStore.turnStopNotification)
            return
        }
        // The turn just started (user hit enter) → start eating now, for *any*
        // prompt, before the injection guards below.
        Self.post(UsageStore.turnStartNotification)

        let prompt = (obj["prompt"] as? String) ?? ""
        let cwd = (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        // Skip trivial prompts (confirmations, one-word replies) for *injection*
        // (the mascot already started above).
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).count >= 6 else { return }

        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        // Only index real project roots — never a home dir or huge folder the
        // agent happens to run in (this fires on *every* prompt).
        guard ContextService.looksLikeProjectRoot(root) else { return }

        // Skip files injected on the previous prompt of this session, so a long
        // session doesn't keep re-injecting the same context every turn.
        let stateURL = Self.stateURL(root: root, sessionID: obj["session_id"] as? String)
        let previous = Self.loadPreviousPaths(stateURL)

        let service = ContextService()
        guard let (allPaths, text) = try? service.promptContext(
            query: prompt, projectRoot: root, excluding: previous) else { return }
        Self.savePreviousPaths(stateURL, allPaths)   // remember this turn's full set

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

    /// Fire a cross-process notification to the menu-bar app, giving the daemon
    /// a beat to deliver it before this short-lived process exits.
    private static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: nil, deliverImmediately: true)
        usleep(40_000)   // 40ms: ensure delivery before exit
    }

    /// Per-(project, session) state file holding the last prompt's injected
    /// paths. Lives under .contextos (self-ignored), so it never dirties git.
    private static func stateURL(root: URL, sessionID: String?) -> URL {
        // Sanitize to a stable filename. NB: String.hashValue is randomly seeded
        // per process, so it must NOT be used here — it'd differ every run.
        let sid = (sessionID ?? "default").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let key = sid.isEmpty ? "default" : String(sid.prefix(64))
        return root.appendingPathComponent(".contextos/.hook-\(key).json")
    }

    private static func loadPreviousPaths(_ url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return Set(arr)
    }

    private static func savePreviousPaths(_ url: URL, _ paths: [String]) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: paths) {
            try? data.write(to: url)
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
