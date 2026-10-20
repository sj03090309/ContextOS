import Foundation

/// The app packager, CLI and MCP all use this release version.
public enum ContextOSVersion {
    public static let current = "2.1.0"
    public static let bundleIdentifier = "com.contextos.app"
}

public struct RuntimeBinaries: Sendable, Equatable {
    public let cli: URL
    public let mcp: URL

    /// Prefer the bundle or siblings of the executable the user actually ran.
    /// This prevents a new installation from registering an older desktop copy.
    public static func resolve(executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               platform: RuntimePlatform = .current, allowInstalledFallback: Bool = true) -> RuntimeBinaries? {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        var candidates = [directory]
        if platform == .macOS, directory.lastPathComponent == "MacOS", directory.deletingLastPathComponent().lastPathComponent == "Contents" {
            candidates.insert(directory.deletingLastPathComponent().appendingPathComponent("Resources"), at: 0)
        }
        if platform == .macOS && allowInstalledFallback {
            candidates += [URL(fileURLWithPath: "/Applications/ContextOS.app/Contents/Resources"),
                           home.appendingPathComponent("Applications/ContextOS.app/Contents/Resources"),
                           home.appendingPathComponent("Desktop/ContextOS.app/Contents/Resources")]
        }
        for directory in candidates {
            let cli = directory.appendingPathComponent("contextos" + platform.executableSuffix)
            let mcp = directory.appendingPathComponent("contextos-mcp" + platform.executableSuffix)
            if FileManager.default.isExecutableFile(atPath: cli.path), FileManager.default.isExecutableFile(atPath: mcp.path) {
                return RuntimeBinaries(cli: cli, mcp: mcp)
            }
        }
        return nil
    }
}
