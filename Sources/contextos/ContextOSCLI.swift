import ArgumentParser
import ContextOSCore
import Foundation

@main
struct ContextOS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "contextos",
        abstract: "Local context manager for Claude Code and Codex.",
        version: ContextOSVersion.current,
        subcommands: [Connect.self, Disconnect.self, RestoreSettings.self, Context.self, Watch.self, Hook.self],
        defaultSubcommand: Connect.self
    )
}

// MARK: - contextos connect

/// Preview first; only --apply changes the selected tool's settings.
struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview safe Claude Code / Codex connection settings.")
    @Option(help: "Claude Code or Codex. Omit to preview detected tools.") var agent: String?
    @Flag(help: "Apply the reviewed settings, with a private local backup.") var apply = false

    func run() throws {
        let manager = try Self.manager()
        let names = agent.map { [$0] } ?? AgentDetector.detect(home: manager.home).map(\.name)
        let agents = names.compactMap(ManagedAgent.init(rawValue:))
        guard !agents.isEmpty else { throw ValidationError("Claude Code 또는 Codex를 지정하거나 먼저 설치해 주세요.") }
        for selected in agents {
            try Self.present(manager.previewConnect(selected), manager: manager, apply: apply)
        }
    }

    static func manager() throws -> ConnectionManager {
        guard let binaries = RuntimeBinaries.resolve(executable: URL(fileURLWithPath: CommandLine.arguments[0])) else {
            throw ValidationError("ContextOS 실행 파일을 찾지 못했습니다. 앱 또는 Release 빌드 폴더에서 실행해 주세요.")
        }
        return ConnectionManager(mcpBinaryPath: binaries.mcp.path, cliBinaryPath: binaries.cli.path)
    }

    static func present(_ preview: ConnectionPreview, manager: ConnectionManager, apply: Bool) throws {
        print("── \(preview.agent.rawValue) · \(preview.action) 미리보기 ──")
        for file in preview.files { print("  \(file): ContextOS 항목 변경") }
        for warning in preview.warnings { print("  \(warning)") }
        guard preview.hasChanges else { print("변경할 설정이 없습니다."); return }
        if apply {
            _ = try manager.apply(preview)
            print("✓ 적용 완료 · 변경 전 백업은 이 Mac의 ~/.contextos-backups에만 보관됩니다.")
            print("도구를 다시 시작하면 설정이 적용됩니다.")
        } else {
            print("설정은 변경하지 않았습니다. 적용하려면 같은 명령에 --apply를 추가하세요.")
        }
    }

}

struct Disconnect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Preview removal of ContextOS-owned settings.")
    @Option(help: "Claude Code or Codex.") var agent: String
    @Flag(help: "Apply the reviewed removal.") var apply = false
    func run() throws {
        guard let selected = ManagedAgent(rawValue: agent) else { throw ValidationError("Claude Code 또는 Codex를 지정해 주세요.") }
        let manager = try Connect.manager()
        try Connect.present(manager.previewDisconnect(selected), manager: manager, apply: apply)
    }
}

struct RestoreSettings: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restore-settings", abstract: "Preview restoration of the latest connection-settings backup.")
    @Option(help: "Claude Code or Codex.") var agent: String
    @Flag(help: "Apply the reviewed restoration.") var apply = false
    func run() throws {
        guard let selected = ManagedAgent(rawValue: agent) else { throw ValidationError("Claude Code 또는 Codex를 지정해 주세요.") }
        let manager = try Connect.manager()
        try Connect.present(manager.previewRestore(selected), manager: manager, apply: apply)
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
            if let stats = try? service.indexer.index(projectRoot: root) {
                let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("♻️  [\(ts)] 다시 읽음: 파일 \(stats.filesIndexed)개")
            }
        }
        guard watcher.start() else { throw ValidationError("파일 감시를 시작하지 못했습니다. 프로젝트 경로와 접근 권한을 확인해 주세요.") }
        RunLoop.main.run()
    }
}
