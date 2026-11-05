import Foundation

/// The MCP tool catalogue advertised via `tools/list`.
///
/// Schemas are plain JSON dictionaries (JSON Schema) so they serialize directly.
public enum MCPToolContract {

    public static let usageInstructions = """
    For code tasks, use ContextOS before broad file searches. At session start, \
    get_project_rules and restore_session provide rules and current state; reuse \
    them if already available. Use read_optimized directly when you need code; \
    get_relevant_context is for a file plan, so you need not call both for the \
    same query. Describe the concrete task and include known symbols or paths. \
    Start with a 4000-8000 estimated token budget and narrow to functions when \
    possible. Reuse returned code; unchanged bodies are elided automatically. \
    Use fresh=true only when earlier context was lost or a full resend is needed. \
    A required-code omission means context is incomplete: request the listed \
    helper specifically or increase the budget before changing its caller. \
    Queries update the index automatically; index_project is for forced rebuilds.
    """

    public static var all: [[String: Any]] {
        [
        [
            "name": "get_relevant_context",
            "description": """
            Return the minimal set of project files relevant to a task, ranked, \
            with token estimates and the reason each was chosen. Use this BEFORE \
            reading files so you only open what matters. If you need code bodies, \
            use read_optimized directly instead. Auto-indexes on first use.
            """,
            "inputSchema": object(
                properties: [
                    "query": string("What you want to work on, e.g. 'fix login flow'."),
                    "path": string("Project root. Defaults to the server's working directory."),
                    "token_budget": integer("Max tokens of context to select. Default 8000.")
                ],
                required: ["query"]
            )
        ],
        [
            "name": "read_optimized",
            "description": """
            Preferred single call when you need code: finds relevant files and \
            returns their actual concatenated contents \
            of the selected files, within a local estimated token budget \
            including headings and outlines — the minimal \
            context to read for the task. Bodies identical to ones already sent in \
            this session are elided; pass fresh=true to force full resend (e.g. \
            after your context was compacted and earlier file contents were lost).
            """,
            "inputSchema": object(
                properties: [
                    "query": string("What you want to work on."),
                    "path": string("Project root. Defaults to the server's working directory."),
                    "token_budget": integer("Max tokens of content to return. Default 8000."),
                    "fresh": boolean("Resend file bodies even if already sent this session. Use after context compaction.")
                ],
                required: ["query"]
            )
        ],
        [
            "name": "index_project",
            "description": "Force a full (re)index of the project. Normally unnecessary — queries auto-index.",
            "inputSchema": object(
                properties: [
                    "path": string("Project root. Defaults to the server's working directory.")
                ],
                required: []
            )
        ],
        [
            "name": "project_stats",
            "description": "Report the current index: file, symbol, and import counts by language.",
            "inputSchema": object(
                properties: [
                    "path": string("Project root. Defaults to the server's working directory.")
                ],
                required: []
            )
        ],
        [
            "name": "get_project_rules",
            "description": """
            Read the project's rule/convention files (.contextos/rules.md, CLAUDE.md, \
            AGENTS.md, .cursorrules) so you can follow project-specific rules. \
            Returns every rule file found, labelled by source.
            """,
            "inputSchema": object(
                properties: [
                    "path": string("Project root. Defaults to the server's working directory.")
                ],
                required: []
            )
        ],
        [
            "name": "restore_session",
            "description": """
            Summarize the current state of the project to orient a new session: \
            git branch, uncommitted changes (what's being worked on), recent \
            commits, and recent ContextOS activity here.
            """,
            "inputSchema": object(
                properties: [
                    "path": string("Project root. Defaults to the server's working directory.")
                ],
                required: []
            )
        ]
        ]
    }

    // MARK: - JSON Schema builders

    private static func object(properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required
        ]
    }

    private static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
}
