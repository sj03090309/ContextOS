import Foundation

/// Backing logic for the `get_project_rules` and `restore_session` MCP tools.
///
/// Both are read-only "orientation" helpers: rules tell the agent *how* to work
/// in this project, the snapshot tells it *where things stand* right now.
public extension ContextService {

    /// Rule files consulted by `get_project_rules`, in reporting order.
    /// `.contextos/rules.md` is ContextOS's own slot; the rest are the de-facto
    /// conventions other tools already write.
    static let ruleFileCandidates = [
        ".contextos/rules.md",
        "CLAUDE.md",
        "AGENTS.md",
        ".cursorrules"
    ]

    /// Concatenate every rule file present in the project, each under a header
    /// naming its source. Returns nil when no rule file exists.
    func projectRules(projectRoot: URL) -> String? {
        var sections: [String] = []
        for candidate in Self.ruleFileCandidates {
            let url = projectRoot.appendingPathComponent(candidate)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            sections.append("===== \(candidate) =====\n\(content.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }

    /// A compact "state of the project" summary for the start of a session:
    /// git branch, uncommitted changes, recent commits, recent ContextOS
    /// optimizations in this project, and index size.
    func sessionSnapshot(projectRoot: URL) -> String {
        var out = ["Session snapshot: \(projectRoot.path)"]

        if git.isRepository(projectRoot) {
            if let branch = git.currentBranch(projectRoot) {
                out.append("Branch: \(branch)")
            }

            let changed = git.changedFiles(projectRoot).sorted()
            if changed.isEmpty {
                out.append("Working tree: clean")
            } else {
                out.append("Uncommitted changes (\(changed.count)) — likely what's being worked on:")
                for path in changed.prefix(15) { out.append("  M \(path)") }
                if changed.count > 15 { out.append("  … and \(changed.count - 15) more") }
            }

            let commits = git.recentCommits(projectRoot, limit: 5)
            if !commits.isEmpty {
                out.append("Recent commits:")
                for c in commits { out.append("  \(c.shortHash) \(c.subject)  (\(c.relativeDate))") }
            }
        } else {
            out.append("Not a git repository.")
        }

        // Recent ContextOS activity in this project (what was asked for lately).
        if let store = try? UsageStore(path: UsageStore.defaultURL().path) {
            let mine = store.recentEvents(limit: 50)
                .filter { $0.project == projectRoot.path }
                .prefix(5)
            if !mine.isEmpty {
                out.append("Recent ContextOS queries here:")
                for e in mine {
                    let query = e.query.isEmpty ? "(proactive)" : e.query
                    out.append("  • \(query)  — \(e.fileCount) files")
                }
            }
        }

        if let s = try? summary(projectRoot: projectRoot) {
            out.append("Index: \(s.files) files, \(s.symbols) symbols, ~\(TokenEstimator.humanReadable(s.estimatedTotalTokens)) if sent whole")
        }

        return out.joined(separator: "\n")
    }
}
