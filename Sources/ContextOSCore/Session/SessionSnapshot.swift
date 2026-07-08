import Foundation

/// A point-in-time capture of "where the project is right now", designed to be
/// handed to a fresh Claude Code session so it starts already oriented.
public struct SessionSnapshot: Codable, Sendable, Equatable {
    public var createdAt: Double
    public var project: String
    public var branch: String?
    public var recentCommits: [String]
    public var changedFiles: [String]
    public var rules: String
    public var note: String?

    public init(
        createdAt: Double = Date().timeIntervalSince1970,
        project: String,
        branch: String?,
        recentCommits: [String],
        changedFiles: [String],
        rules: String,
        note: String? = nil
    ) {
        self.createdAt = createdAt
        self.project = project
        self.branch = branch
        self.recentCommits = recentCommits
        self.changedFiles = changedFiles
        self.rules = rules
        self.note = note
    }

    /// A readable handoff block for a new session.
    public func rendered() -> String {
        let date = Date(timeIntervalSince1970: createdAt)
        let stamp = DateFormatter.snapshot.string(from: date)
        var lines = ["세션 스냅샷 — \(URL(fileURLWithPath: project).lastPathComponent) (\(stamp))"]
        if let branch { lines.append("브랜치: \(branch)") }
        if let note { lines.append("메모: \(note)") }
        if !recentCommits.isEmpty {
            lines.append("최근 커밋:")
            lines.append(contentsOf: recentCommits.map { "  - \($0)" })
        }
        if !changedFiles.isEmpty {
            lines.append("변경된 파일 (\(changedFiles.count)개):")
            lines.append(contentsOf: changedFiles.prefix(20).map { "  - \($0)" })
        }
        if rules != "(no rules set)" {
            lines.append("프로젝트 규칙:")
            lines.append(contentsOf: rules.split(separator: "\n").map { "  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

private extension DateFormatter {
    static let snapshot: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
}

/// Persists and captures `SessionSnapshot`s under `.contextos/snapshot.json`.
public enum SessionSnapshotStore {

    public static func url(forProjectRoot root: URL) -> URL {
        root.appendingPathComponent(".contextos", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    /// Build a snapshot from the project's *current* live state.
    public static func capture(projectRoot root: URL, note: String? = nil, git: GitAnalyzer = GitAnalyzer()) -> SessionSnapshot {
        let branch = git.currentBranch(root)
        let commits = git.recentCommits(root, limit: 5).map { "\($0.shortHash) \($0.subject)" }
        let changed = git.changedFiles(root).sorted()
        let rules = ProjectRulesStore.effective(projectRoot: root).rendered()
        return SessionSnapshot(
            project: root.path, branch: branch, recentCommits: commits,
            changedFiles: changed, rules: rules, note: note
        )
    }

    public static func save(_ snapshot: SessionSnapshot, projectRoot root: URL) throws {
        let url = url(forProjectRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url)
    }

    public static func load(projectRoot root: URL) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url(forProjectRoot: root)) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
