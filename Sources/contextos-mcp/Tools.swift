import Foundation

/// The MCP tool catalogue advertised via `tools/list`.
///
/// Schemas are plain JSON dictionaries (JSON Schema) so they serialize directly.
enum Tools {

    static var all: [[String: Any]] {
        [
        [
            "name": "get_relevant_context",
            "description": """
            Return the minimal set of project files relevant to a task, ranked, \
            with token estimates and the reason each was chosen. Use this BEFORE \
            reading files so you only open what matters. Auto-indexes on first use.
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
            Like get_relevant_context, but returns the actual concatenated contents \
            of the selected files, already within the token budget — the minimal \
            context to read for the task.
            """,
            "inputSchema": object(
                properties: [
                    "query": string("What you want to work on."),
                    "path": string("Project root. Defaults to the server's working directory."),
                    "token_budget": integer("Max tokens of content to return. Default 8000.")
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
}
