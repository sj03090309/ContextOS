import Foundation

/// A commit summary from `git log`.
public struct GitCommit: Sendable, Equatable {
    public var shortHash: String
    public var subject: String
    public var author: String
    public var relativeDate: String
}

/// Ranking signals derived from Git state, consumed by the optimizer.
public struct GitSignals: Sendable {
    /// Files with uncommitted changes in the working tree.
    public var changedPaths: Set<String>
    /// Files touched by recent commits.
    public var recentPaths: Set<String>

    public static let empty = GitSignals(changedPaths: [], recentPaths: [])

    public var isEmpty: Bool { changedPaths.isEmpty && recentPaths.isEmpty }
}

/// Reads Git state by shelling out to the system `git`.
///
/// No libgit2 dependency: `git` is already on every dev machine, and this keeps
/// ContextOS's promise of no heavyweight third-party code. All calls degrade
/// gracefully (return nil/empty) outside a repository.
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
        guard let out = run(["status", "--porcelain"], in: root) else { return [] }
        var paths: Set<String> = []
        for line in out.split(separator: "\n") {
            // Porcelain: "XY <path>" or "XY <old> -> <new>" for renames.
            let entry = String(line.dropFirst(3))
            let path: String
            if let arrow = entry.range(of: " -> ") {
                path = String(entry[arrow.upperBound...])
            } else {
                path = entry
            }
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
        guard let out = run(["log", "-n", "\(commitLimit)", "--name-only", "--pretty=format:"], in: root) else { return [] }
        var paths: Set<String> = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !Self.isInternal(trimmed) { paths.insert(trimmed) }
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

    /// Standard git location, resolved once. Prefer the absolute path over a
    /// PATH lookup so a malicious `git` earlier in PATH can't be invoked.
    private static let gitExecutable: URL = {
        for candidate in ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Run `git <args>` in `root`, returning stdout, or nil on failure.
    private func run(_ args: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = Self.gitExecutable
        process.arguments = args
        process.currentDirectoryURL = root

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
