import Foundation
import CoreFoundation
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
    static let version = ContextOSVersion.current
    static let defaultProtocolVersion = RuntimeContract.mcpProtocolVersion

    #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
    let service = ContextService()
    /// Per-session dedup: bodies already delivered aren't resent while this
    /// MCP process (i.e. this agent session) is alive.
    let memory = SessionMemory()
    /// Cross-process "an agent is using me right now" signal for the menu-bar
    /// mascot, throttled to one post per second.
    let heartbeat = Heartbeat()
    #endif

    func run() {
        log("contextos-mcp \(Self.version) started (stdio)")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: .fragmentsAllowed)
            } catch {
                replyError(id: NSNull(), code: -32700, message: "Parse error")
                continue
            }
            guard let message = object as? [String: Any] else {
                replyError(id: NSNull(), code: -32600, message: "Invalid Request")
                continue
            }
            handle(message)
        }
        log("stdin closed, exiting")
    }

    // MARK: - Dispatch

    private func handle(_ message: [String: Any]) {
        let id = message["id"]           // absent → notification (no reply)
        let validID = id == nil || id is NSNull || id is String
            || (id is NSNumber && CFGetTypeID(id as! NSNumber) != CFBooleanGetTypeID())
        guard message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String, !method.isEmpty, validID else {
            replyError(id: validID ? (id ?? NSNull()) : NSNull(), code: -32600, message: "Invalid Request")
            return
        }
        guard message["params"] == nil || message["params"] is [String: Any] else {
            replyError(id: id, code: -32602, message: "Invalid params: expected an object")
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]

        // Only real work counts as "the agent is busy". `ping`, `initialize`,
        // `tools/list` and the initialized notification are connection
        // bookkeeping — Claude Code sends a keepalive `ping` on an idle
        // connection, so firing the heartbeat for every message made the mascot
        // eat whenever a session was merely *open*, with nothing being asked.
        #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
        if UsageStore.isAgentActivity(method: method) { heartbeat.post() }
        #endif

        switch method {
        case "initialize":
            reply(id: id, result: initializeResult())
        case "notifications/initialized", "initialized":
            break // notification, nothing to return
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": MCPToolContract.all])
        case "tools/call":
            handleToolCall(id: id, params: params)
        default:
            if id != nil {
                replyError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func initializeResult() -> [String: Any] {
        var result: [String: Any] = [
            // This server implements one revision. Unsupported client versions
            // must negotiate that revision instead of being echoed as supported.
            "protocolVersion": Self.defaultProtocolVersion,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": Self.name, "version": Self.version],
            "instructions": MCPToolContract.usageInstructions
        ]
        if !RuntimeSupport.permits(.projectFiles) {
            result["instructions"] = PlatformSupportError(platform: .current, operation: .projectFiles).localizedDescription
        }
        return result
    }

    // MARK: - Tool calls

    private func handleToolCall(id: Any?, params: [String: Any]) {
        let name = params["name"] as? String ?? ""
        guard let contract = MCPToolContract.all.first(where: { $0["name"] as? String == name }),
              params["arguments"] == nil || params["arguments"] is [String: Any] else {
            replyError(id: id, code: -32602, message: "Invalid tool name or arguments")
            return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        guard validArguments(args, contract: contract) else {
            replyError(id: id, code: -32602, message: "Invalid tool arguments")
            return
        }

        do {
            try RuntimeSupport.require(.projectFiles)
            #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
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
            #endif
        } catch let error as PlatformSupportError {
            reply(id: id, result: toolResult(error.localizedDescription, isError: true))
        } catch {
            log("tool request failed")
            reply(id: id, result: toolResult("Unable to process this project request.", isError: true))
        }
    }

    #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
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
        // Planning call — points at files but delivers no content, so it records
        // no saving (only read_optimized, the delivery, does).
        let selection = try service.relevantContext(query: query, projectRoot: root, tokenBudget: budget)

        guard !selection.isEmpty else {
            return "No relevant files found."
        }

        var out = """
        Query: \(SensitiveFilePolicy.redactingReferences(in: query))
        Context Score: \(selection.contextScore)/100  |  Budget: \(TokenEstimator.humanReadable(selection.tokenBudget))  |  Estimated: \(TokenEstimator.humanReadable(selection.estimatedTokens))

        Suggested starting files within the estimated budget (\(selection.included.count)):
        """
        for file in selection.included {
            let reason = file.reasons.first ?? ""
            out += "\n  - \(file.path)  (\(TokenEstimator.humanReadable(file.estimatedTokens)))  — \(reason)"
        }
        if !selection.excluded.isEmpty {
            let names = selection.excluded.prefix(8).map(\.path).joined(separator: ", ")
            out += "\n\nAdditional ranked files outside this delivery budget: \(names)"
        }
        if !selection.omissions.isEmpty { out += "\n\nRequired code incomplete: " + selection.omissions.joined(separator: "; ") }
        out += "\n\nTip: fetch these with `read_optimized` to get their contents inside the budget."
        return out
    }

    private func toolReadOptimized(_ args: [String: Any]) throws -> String {
        guard let query = string(args, "query"), !query.isEmpty else {
            throw ToolError.missing("query")
        }
        let root = projectRoot(from: args)
        let budget = integer(args, "token_budget") ?? 8000
        // fresh=true bypasses the session dedup — the agent lost earlier
        // context (compaction) and needs the bodies again.
        let fresh = (args["fresh"] as? Bool) ?? false
        let (selection, bundle, _, deliveredFull, deliveredTokens) = try service.optimizedBundle(
            query: query, projectRoot: root, tokenBudget: budget, memory: fresh ? nil : memory
        )
        guard !selection.isEmpty else {
            return "No relevant files found."
        }
        // Honest delivery saving: full size of the files actually delivered vs
        // the complete sliced/deduped response, including any outline.
        service.recordDelivery(
            query: query, projectRoot: root,
            fullTokens: deliveredFull, deliveredTokens: deliveredTokens,
            contextScore: selection.contextScore, fileCount: selection.included.count)
        // Bundle framing and per-file dedup markers are already included in
        // its budget. Adding another header here would exceed small budgets.
        return bundle
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

    #endif

    private func integer(_ args: [String: Any], _ key: String) -> Int? {
        if let n = args[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return Int(n.stringValue) ?? Int(exactly: n.doubleValue)
        }
        return nil
    }

    private func validArguments(_ args: [String: Any], contract: [String: Any]) -> Bool {
        guard let schema = contract["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: [String: Any]],
              let required = schema["required"] as? [String],
              required.allSatisfy({ args[$0] != nil }) else { return false }
        for (key, value) in args {
            guard let property = properties[key] else { continue }
            switch property["type"] as? String {
            case "string":
                guard let string = value as? String, !string.contains("\0"),
                      key != "query" || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            case "integer": guard integer(args, key) != nil else { return false }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            default: return false
            }
        }
        return true
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
#if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
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

#endif

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
