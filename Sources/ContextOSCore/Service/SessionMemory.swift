import Foundation

/// Remembers what was already delivered during one MCP session, so repeat
/// queries never pay for the same bytes twice.
///
/// Keyed by (project, path) → hash of the *delivered body* (post-slicing).
/// If a later query would deliver the identical body, the bundle replaces it
/// with a one-line "already in your context" marker. A changed file — or a
/// different slice of the same file — is delivered in full again.
public final class SessionMemory: @unchecked Sendable {

    private var served: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    private func key(_ project: String, _ path: String) -> String {
        project + "\u{1f}" + path
    }

    /// Whether this exact body was already delivered for (project, path).
    public func isUnchanged(project: String, path: String, bodyHash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return served[key(project, path)] == bodyHash
    }

    public func markServed(project: String, path: String, bodyHash: String) {
        lock.lock(); defer { lock.unlock() }
        served[key(project, path)] = bodyHash
    }

    /// Number of distinct files remembered (for tests/telemetry).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return served.count
    }
}
