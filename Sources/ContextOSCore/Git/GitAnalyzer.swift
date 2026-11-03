import Foundation

/// A commit summary from `git log`.
public struct GitCommit: Sendable, Equatable {
    public var shortHash: String
    public var subject: String
    public var author: String
    public var relativeDate: String
}

/// Runs the system `git`.
///
/// No libgit2 dependency: `git` is already on every dev machine, and this keeps
/// ContextOS's promise of no heavyweight third-party code.
public enum GitRunner {

    /// Standard git location, resolved once. Prefer the absolute path over a
    /// PATH lookup so a malicious `git` earlier in PATH can't be invoked.
    static let executable: URL = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Run `git <args>` in `root`, returning stdout, or nil on failure.
    public static func run(_ args: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = root

        let stdout = Pipe()
        process.standardOutput = stdout
        // Discard diagnostics directly: an undrained second pipe can fill
        // before stdout reaches EOF and deadlock this reader.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a commit-heavy `git log` can fill the pipe buffer,
        // and git would block on write while we block on exit.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Reads Git state by shelling out to the system `git`.
///
/// All calls degrade gracefully (return nil/empty) outside a repository.
public struct GitAnalyzer: Sendable {

    /// Field separator unlikely to appear in commit text.
    private static let unit = "\u{1f}"

    public init() {}

    public func isRepository(_ root: URL) -> Bool {
        run(["rev-parse", "--is-inside-work-tree"], in: root)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func currentBranch(_ root: URL) -> String? {
        guard let out = run(["rev-parse", "--abbrev-ref", "HEAD"], in: root) else { return nil }
        let branch = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    public func recentCommits(_ root: URL, limit: Int = 5) -> [GitCommit] {
        let format = ["%h", "%s", "%an", "%ar"].joined(separator: Self.unit)
        guard let out = run(["log", "-n", "\(limit)", "--pretty=format:\(format)"], in: root) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: Self.unit)
            guard parts.count == 4 else { return nil }
            return GitCommit(shortHash: parts[0], subject: parts[1], author: parts[2], relativeDate: parts[3])
        }
    }

    /// Files with uncommitted changes (staged or unstaged), project-relative.
    public func changedFiles(_ root: URL) -> Set<String> {
        guard let out = run(["status", "--porcelain=v1", "-z"], in: root) else { return [] }
        var paths: Set<String> = []
        var entries = out.split(separator: "\0").makeIterator()
        while let entry = entries.next() {
            guard entry.count >= 3 else { continue }
            let status = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            // NUL porcelain reports destination first, then source separately.
            if status.contains("R") || status.contains("C") { _ = entries.next() }
            if !Self.isInternal(path) { paths.insert(path) }
        }
        return paths
    }

    /// ContextOS's own artifacts shouldn't appear as project changes.
    private static func isInternal(_ path: String) -> Bool {
        path.hasPrefix(".contextos/")
    }

    /// Files touched by the most recent commits, project-relative.
    public func recentlyModifiedFiles(_ root: URL, commitLimit: Int = 10) -> Set<String> {
        guard let out = run(["log", "-n", "\(commitLimit)", "--name-only", "--format=", "-z"], in: root) else { return [] }
        var paths: Set<String> = []
        for entry in out.split(separator: "\0") {
            let path = String(entry)
            if !Self.isInternal(path) { paths.insert(path) }
        }
        return paths
    }

    /// Gather the ranking signals in one call (empty outside a repo).
    public func signals(_ root: URL, commitLimit: Int = 10) -> GitSignals {
        guard isRepository(root) else { return .empty }
        return GitSignals(
            changedPaths: changedFiles(root),
            recentPaths: recentlyModifiedFiles(root, commitLimit: commitLimit)
        )
    }

    // MARK: - Process runner

    private func run(_ args: [String], in root: URL) -> String? {
        GitRunner.run(args, in: root)
    }
}
