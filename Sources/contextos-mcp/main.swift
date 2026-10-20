import Foundation
import ContextOSCore

// Executable entry point. Top-level code is allowed in `main.swift`, which keeps
// the server free of the `@main`-in-main.swift restriction.
if CommandLine.arguments.dropFirst().contains("--version") {
    print(ContextOSVersion.current)
} else if CommandLine.arguments.dropFirst().contains("--contract") {
    FileHandle.standardOutput.write(try RuntimeContract.jsonData())
    FileHandle.standardOutput.write(Data([0x0A]))
} else {
    MCPServer().run()
}
