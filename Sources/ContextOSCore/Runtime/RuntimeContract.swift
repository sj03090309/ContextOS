import Foundation

/// One source for CLI/MCP release identity, advertised tool schemas and the
/// compatibility check. Platform readiness is reported separately by doctor.
public enum RuntimeContract {
    public static let schemaVersion = 1
    public static let mcpProtocolVersion = "2024-11-05"
    public static let cliCommands = ["connect", "disconnect", "restore-settings", "context", "watch", "hook", "doctor", "contract"]

    public static func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema_version": schemaVersion,
            "version": ContextOSVersion.current,
            "cli_commands": cliCommands,
            "mcp_protocol_version": mcpProtocolVersion,
            "mcp_tools": MCPToolContract.all
        ], options: [.sortedKeys])
    }
}
