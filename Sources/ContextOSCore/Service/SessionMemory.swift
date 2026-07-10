import Foundation

/// Remembers what was already delivered during one MCP session, so repeat
/// queries never pay for the same bytes twice.
///
/// Keyed by (project, path) → hash of the *delivered body* (post-slicing).
/// If a later query would deliver the identical body, the bundle replaces it
/// with a one-line "already in your context" marker. A changed file — or a
/// different slice of the same file — is delivered in full again.
///
/// Entries expire after `ttl`: agents compact/summarize long conversations,
/// and once that happens a body we sent earlier is no longer in their context.
/// A bounded memory means the worst case after compaction is one resend, never
/// a permanently withheld file. `read_optimized`'s `fresh` flag bypasses the
/// memory entirely for the same reason.
public final class SessionMemory: @unchecked Sendable {

    private var served: [String: (hash: String, at: Date)] = [:]
    private let lock = NSLock()
    /// How long a delivered body stays "known" before we resend it anyway.
    public let ttl: TimeInterval

    public init(ttl: TimeInterval = 15 * 60) {
        self.ttl = ttl
    }

    private func key(_ project: String, _ path: String) -> String {
        project + "\u{1f}" + path
    }

    /// Whether this exact body was already delivered for (project, path) —
    /// recently enough that it's still plausibly in the agent's context.
    public func isUnchanged(project: String, path: String, bodyHash: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = served[key(project, path)] else { return false }
        return entry.hash == bodyHash && now.timeIntervalSince(entry.at) <= ttl
    }

    public func markServed(project: String, path: String, bodyHash: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        served[key(project, path)] = (bodyHash, now)
    }

    /// Number of distinct files remembered (for tests/telemetry).
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return served.count
    }
}
