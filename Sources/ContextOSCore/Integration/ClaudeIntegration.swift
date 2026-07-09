import Foundation

/// Wires ContextOS into Claude Code so it's used **automatically** — the user
/// never opens the app. The mechanism: a marked instruction block in Claude
/// Code's memory file (`~/.claude/CLAUDE.md` globally, or a project `CLAUDE.md`)
/// that tells Claude Code to call ContextOS's tools before exploring files.
public enum ClaudeIntegration {

    static let beginMarker = "<!-- ContextOS:begin -->"
    static let endMarker = "<!-- ContextOS:end -->"

    public static func globalMemoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/CLAUDE.md")
    }

    public static func projectMemoryURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent("CLAUDE.md")
    }

    /// Whether the global auto-use instruction is installed (i.e. Claude Code is
    /// wired to use ContextOS automatically).
    public static func isGloballyInstalled() -> Bool {
        guard let content = try? String(contentsOf: globalMemoryURL(), encoding: .utf8) else { return false }
        return content.contains(beginMarker)
    }

    /// The instruction Claude Code follows. Kept concise and directive so the
    /// model reliably prefers ContextOS over broad file exploration.
    public static func instructionBody() -> String {
        """
        ## ContextOS — 컨텍스트 최적화 (자동)

        이 환경에는 `contextos` MCP 서버가 연결되어 있습니다. 코드베이스에서 어떤
        작업을 이해하거나 수정하기 위해 **여러 파일을 읽어야 할 때, 파일을 직접
        탐색하기 전에 먼저 ContextOS를 사용하세요.**

        - 관련 파일만 빠르게 찾으려면 `get_relevant_context`(경로+이유) 또는
          `read_optimized`(관련 함수만 잘라낸 내용)를 호출하세요.
        - 프로젝트 전체를 넓게 grep/read 하지 말고, ContextOS가 고른 파일부터 보세요.
          토큰을 크게 아낄 수 있습니다.
        - 프로젝트 규칙은 `get_project_rules`, 새 세션 시작 시 현재 상태 파악은
          `restore_session`을 사용하세요.
        """
    }

    private static func markedBlock() -> String {
        "\(beginMarker)\n\(instructionBody())\n\(endMarker)"
    }

    /// Install (or update) the instruction block in `url`, idempotently. Existing
    /// content outside the markers is preserved. Returns whether an existing
    /// block was updated (true) vs. freshly added (false).
    @discardableResult
    public static func installInstruction(at url: URL) throws -> Bool {
        let block = markedBlock()
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        let updated: Bool
        if let begin = content.range(of: beginMarker),
           let end = content.range(of: endMarker), end.upperBound >= begin.lowerBound {
            content.replaceSubrange(begin.lowerBound..<end.upperBound, with: block)
            updated = true
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
            if !content.isEmpty { content += "\n" }
            content += block + "\n"
            updated = false
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return updated
    }

    /// Remove the ContextOS block from `url` (leaving other content intact).
    public static func removeInstruction(at url: URL) throws {
        guard var content = try? String(contentsOf: url, encoding: .utf8),
              let begin = content.range(of: beginMarker),
              let end = content.range(of: endMarker), end.upperBound >= begin.lowerBound
        else { return }
        content.replaceSubrange(begin.lowerBound..<end.upperBound, with: "")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The command to register the MCP server for **all** projects (user scope).
    public static func mcpAddCommand(mcpBinaryPath: String) -> String {
        "claude mcp add --scope user contextos -- \"\(mcpBinaryPath)\""
    }

    /// Write a project-local `.mcp.json` pointing at the MCP server.
    public static func writeProjectMCPConfig(projectRoot: URL, mcpBinaryPath: String) throws {
        let config: [String: Any] = [
            "mcpServers": ["contextos": ["command": mcpBinaryPath, "args": [String]()]]
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try data.write(to: projectRoot.appendingPathComponent(".mcp.json"))
    }
}
