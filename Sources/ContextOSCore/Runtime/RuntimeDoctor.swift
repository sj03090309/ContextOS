import Foundation

public struct DoctorCheck: Codable, Sendable {
    public let name: String
    public let passed: Bool
    public let detail: String
}

public struct DoctorReport: Codable, Sendable {
    public let version: String
    public let platform: RuntimePlatform
    public let readyToConnect: Bool
    public let agentToolCallVerified: Bool
    public let checks: [DoctorCheck]
}

/// Checks only this installation's binaries. Never reads or modifies agent
/// configuration, projects, account secrets or conversation logs.
public enum RuntimeDoctor {
    public static func inspect(executable: URL,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               platform: RuntimePlatform = .current,
                               readVersion: (URL) -> String? = probeVersion) -> DoctorReport {
        guard RuntimeSupport.permits(.projectFiles, on: platform) else {
            return DoctorReport(version: ContextOSVersion.current, platform: platform,
                                readyToConnect: false, agentToolCallVerified: false,
                                checks: [DoctorCheck(name: "platform_security", passed: false,
                                    detail: PlatformSupportError(platform: platform, operation: .projectFiles).localizedDescription)])
        }
        guard let binaries = RuntimeBinaries.resolve(executable: executable, home: home, platform: platform,
                                                     allowInstalledFallback: false) else {
            return DoctorReport(version: ContextOSVersion.current, platform: platform,
                                readyToConnect: false, agentToolCallVerified: false,
                                checks: [DoctorCheck(name: "runtime_pair", passed: false,
                                    detail: "CLI and MCP binaries are missing. Keep the complete ContextOS app together and run its bundled CLI.")])
        }
        let cliVersion = readVersion(binaries.cli), mcpVersion = readVersion(binaries.mcp)
        let matches = cliVersion == ContextOSVersion.current && mcpVersion == ContextOSVersion.current
        return DoctorReport(version: ContextOSVersion.current, platform: platform,
                            readyToConnect: matches, agentToolCallVerified: false,
                            checks: [
                                DoctorCheck(name: "runtime_pair", passed: true, detail: "CLI and MCP were found in the same installation."),
                                DoctorCheck(name: "shared_version", passed: matches,
                                    detail: matches ? "CLI and MCP match \(ContextOSVersion.current). Restart the agent and verify its ContextOS tool list."
                                        : "The bundled CLI/MCP could not confirm matching versions. Replace the complete app at the same location; do not mix individual binaries.")
                            ])
    }

    public static func probeVersion(_ binary: URL) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            process.terminate() // Only our own --version diagnostic child.
            return nil
        }
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Do not echo arbitrary output from a broken executable in diagnostics.
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        return version
    }
}
