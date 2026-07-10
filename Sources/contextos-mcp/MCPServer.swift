import Foundation
import ContextOSCore

/// A minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
///
/// Exposes ContextOS to Claude Code as tools. Deliberately dependency-free and
/// synchronous: MCP requests arrive one line at a time and are handled in order.
///
/// Protocol invariant: **stdout carries only JSON-RPC**. All logging goes to
/// stderr via `log(_:)`.
struct MCPServer {

    static let name = "contextos"
    static let version = "0.3.0"
    static let defaultProtocolVersion = "2024-11-05"

    let service = ContextService()
    /// Per-session dedup: bodies already delivered aren't resent while this
    /// MCP process (i.e. this agent session) is alive.
    let memory = SessionMemory()
    /// Cross-process "an agent is using me right now" signal for the menu-bar
    /// mascot, throttled to one post per second.
    let heartbeat = Heartbeat()

    func run() {
        log("contextos-mcp \(Self.version) started (stdio)")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                log("failed to parse line as JSON: \(trimmed.prefix(120))")
                continue
            }
            handle(message)
        }
        log("stdin closed, exiting")
    }

    // MARK: - Dispatch

    private func handle(_ message: [String: Any]) {
        heartbeat.post()
        let method = message["method"] as? String ?? ""
        let id = message["id"]           // absent → notification (no reply)
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            reply(id: id, result: initializeResult(params: params))
        case "notifications/initialized", "initialized":
            break // notification, nothing to return
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": Tools.all])
        case "tools/call":
            handleToolCall(id: id, params: params)
        default:
            if id != nil {
                replyError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        return [
            "protocolVersion": requested ?? Self.defaultProtocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": Self.name, "version": Self.version]
        ]
    }

    // MARK: - Tool calls

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text: String
            switch name {
            case "index_project":
                text = try toolIndexProject(args)
            case "get_relevant_context":
                text = try toolGetRelevantContext(args)
            case "read_optimized":
                text = try toolReadOptimized(args)
            case "project_stats":
                text = try toolProjectStats(args)
            case "get_project_rules":
                text = toolProjectRules(args)
            case "restore_session":
                text = toolRestoreSession(args)
            default:
                reply(id: id, result: toolResult("Unknown tool: \(name)", isError: true))
                return
            }
            reply(id: id, result: toolResult(text))
        } catch {
            log("tool \(name) failed: \(error)")
            reply(id: id, result: toolResult("Error: \(error)", isError: true))
        }
    }

    private func toolIndexProject(_ args: [String: Any]) throws -> String {
        let root = projectRoot(from: args)
        let stats = try service.reindex(projectRoot: root)
        var lines = [
            "Indexed \(root.path)",
            "files: \(stats.filesIndexed) (skipped \(stats.filesSkipped)), symbols: \(stats.symbolsIndexed), imports: \(stats.importsIndexed)"
        ]
        if !stats.byLanguage.isEmpty {
            let langs = stats.byLanguage.sorted { $0.value > $1.value }
                .map { "\($0.key.displayName) \($0.value)" }.joined(separator: ", ")
            lines.append("languages: \(langs)")
        }
        return lines.joined(separator: "\n")
    }

    private func toolGetRelevantContext(_ args: [String: Any]) throws -> String {
        guard let query = string(args, "query"), !query.isEmpty else {
            throw ToolError.missing("query")
        }
        let root = projectRoot(from: args)
        let budget = integer(args, "token_budget") ?? 8000
        let selection = try service.relevantContext(query: query, projectRoot: root, tokenBudget: budget)
        service.recordUsage(for: selection, query: query, projectRoot: root)

        guard !selection.isEmpty else {
            return "No relevant files found for “\(query)”. Terms: \(selection.terms.joined(separator: ", "))"
        }

        var out = """
        Query: \(query)
        Context Score: \(selection.contextScore)/100  |  Budget: \(TokenEstimator.humanReadable(selection.tokenBudget))  |  Estimated: \(TokenEstimator.humanReadable(selection.estimatedTokens))

        Read ONLY these \(selection.included.count) files (already within budget):
        """
        for file in selection.included {
            let reason = file.reasons.first ?? ""
            out += "\n  - \(file.path)  (\(TokenEstimator.humanReadable(file.estimatedTokens)))  — \(reason)"
        }
        if !selection.excluded.isEmpty {
            let names = selection.excluded.prefix(8).map(\.path).joined(separator: ", ")
            out += "\n\nRelevant but over budget (not included): \(names)"
        }
        out += "\n\nTip: fetch these with `read_optimized` to get their contents inside the budget."
        return out
    }

    private func toolReadOptimized(_ args: [String: Any]) throws -> String {
        guard let query = string(args, "query"), !query.isEmpty else {
            throw ToolError.missing("query")
        }
        let root = projectRoot(from: args)
        let budget = integer(args, "token_budget") ?? 8000
        let (selection, bundle, skipped) = try service.optimizedBundle(
            query: query, projectRoot: root, tokenBudget: budget, memory: memory
        )
        guard !selection.included.isEmpty else {
            return "No relevant files found for “\(query)”."
        }
        var header = "// ContextOS: \(selection.included.count) files, \(TokenEstimator.humanReadable(selection.estimatedTokens)) (budget \(TokenEstimator.humanReadable(budget))), score \(selection.contextScore)/100\n"
        if skipped > 0 {
            header += "// \(skipped)개 파일은 이 세션에서 이미 전달된 것과 동일 — 본문 생략으로 토큰 절약\n"
        }
        return header + "\n" + bundle
    }

    private func toolProjectStats(_ args: [String: Any]) throws -> String {
        let root = projectRoot(from: args)
        try service.ensureIndexed(projectRoot: root)
        let s = try service.summary(projectRoot: root)
        var out = "Index for \(root.path)\nfiles: \(s.files), symbols: \(s.symbols), imports: \(s.imports)"
        if !s.byLanguage.isEmpty {
            let langs = s.byLanguage.sorted { $0.value > $1.value }
                .map { "\($0.key.displayName) \($0.value)" }.joined(separator: ", ")
            out += "\nlanguages: \(langs)"
        }
        return out
    }

    private func toolProjectRules(_ args: [String: Any]) -> String {
        let root = projectRoot(from: args)
        guard let rules = service.projectRules(projectRoot: root) else {
            return "No project rule files found (looked for: \(ContextService.ruleFileCandidates.joined(separator: ", "))). "
                 + "Create .contextos/rules.md to add project-specific rules."
        }
        return rules
    }

    private func toolRestoreSession(_ args: [String: Any]) -> String {
        let root = projectRoot(from: args)
        // Best-effort index so the snapshot can report project size; a failure
        // here shouldn't block the git/status half of the summary.
        _ = try? service.ensureIndexed(projectRoot: root)
        return service.sessionSnapshot(projectRoot: root)
    }

    // MARK: - Argument helpers

    private func projectRoot(from args: [String: Any]) -> URL {
        let path = string(args, "path") ?? FileManager.default.currentDirectoryPath
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func string(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private func integer(_ args: [String: Any], _ key: String) -> Int? {
        if let n = args[key] as? NSNumber { return n.intValue }
        if let i = args[key] as? Int { return i }
        return nil
    }

    // MARK: - JSON-RPC output

    private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func reply(id: Any?, result: [String: Any]) {
        guard let id else { return } // notification: no reply
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            log("failed to serialize response")
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A])) // newline delimiter
    }
}

/// Posts the cross-process activity notification, at most once per second.
final class Heartbeat {
    private var last = Date.distantPast
    func post() {
        let now = Date()
        guard now.timeIntervalSince(last) >= 1 else { return }
        last = now
        DistributedNotificationCenter.default().postNotificationName(
            UsageStore.activityNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}

enum ToolError: Error, CustomStringConvertible {
    case missing(String)
    var description: String {
        switch self {
        case .missing(let field): return "Missing required argument: \(field)"
        }
    }
}

/// stderr logger — keeps stdout clean for the protocol.
func log(_ message: String) {
    FileHandle.standardError.write(Data(("[contextos-mcp] " + message + "\n").utf8))
}
