import Foundation

public enum RuntimePlatform: String, Codable, Sendable {
    case macOS = "macos", windows, unsupported

    public static var current: Self {
        #if os(macOS)
        return .macOS
        #elseif os(Windows)
        return .windows
        #else
        return .unsupported
        #endif
    }

    public var executableSuffix: String { self == .windows ? ".exe" : "" }
}

public enum ProtectedOperation: String, Codable, Sendable {
    case projectFiles = "project_files", settingsChanges = "settings_changes", fileWatching = "file_watching"
}

public struct PlatformSupportError: Error, LocalizedError, Equatable {
    public let platform: RuntimePlatform
    public let operation: ProtectedOperation
    public init(platform: RuntimePlatform, operation: ProtectedOperation) {
        self.platform = platform
        self.operation = operation
    }
    public var errorDescription: String? {
        "ContextOS \(platform.rawValue) is a preparation build. \(operation.rawValue) is disabled until protected file access, locking and private backup permissions are implemented and verified. No project or agent settings were changed."
    }
}

/// Availability describes implemented security adapters, not whether Swift can
/// compile on an OS. A preparation build never falls back to unsafe file I/O.
public enum RuntimeSupport {
    public static func permits(_ operation: ProtectedOperation, on platform: RuntimePlatform = .current) -> Bool {
        #if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
        return platform == .macOS
        #else
        return false
        #endif
    }

    public static func require(_ operation: ProtectedOperation, on platform: RuntimePlatform = .current) throws {
        guard permits(operation, on: platform) else {
            throw PlatformSupportError(platform: platform, operation: operation)
        }
    }
}
