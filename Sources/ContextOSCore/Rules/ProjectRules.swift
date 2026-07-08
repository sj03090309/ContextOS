import Foundation

/// Persistent, human-editable project conventions that should survive across
/// Claude Code sessions (language, framework, style, freeform notes).
///
/// Stored as `.contextos/rules.json`. When absent, `effective(...)` derives a
/// minimal default from the index (dominant language) so there's always
/// something useful to hand Claude Code — the "configure nothing" philosophy.
public struct ProjectRules: Codable, Sendable, Equatable {
    public var language: String?
    public var framework: String?
    public var style: [String]
    public var notes: [String]

    public init(language: String? = nil, framework: String? = nil, style: [String] = [], notes: [String] = []) {
        self.language = language
        self.framework = framework
        self.style = style
        self.notes = notes
    }

    public var isEmpty: Bool {
        language == nil && framework == nil && style.isEmpty && notes.isEmpty
    }

    /// A compact block suitable for injecting into an AI session.
    public func rendered() -> String {
        var lines: [String] = []
        if let language { lines.append("Language: \(language)") }
        if let framework { lines.append("Framework: \(framework)") }
        if !style.isEmpty { lines.append("Style: \(style.joined(separator: ", "))") }
        for note in notes { lines.append("Note: \(note)") }
        return lines.isEmpty ? "(no rules set)" : lines.joined(separator: "\n")
    }
}

/// Loads/saves `ProjectRules`, and derives sensible defaults from an index.
public enum ProjectRulesStore {

    public static func url(forProjectRoot root: URL) -> URL {
        root.appendingPathComponent(".contextos", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    /// Load explicit rules, or nil if none saved.
    public static func load(projectRoot root: URL) -> ProjectRules? {
        let url = url(forProjectRoot: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectRules.self, from: data)
    }

    public static func save(_ rules: ProjectRules, projectRoot root: URL) throws {
        let url = url(forProjectRoot: root)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rules).write(to: url)
    }

    /// Saved rules if present, otherwise a default inferred from the index's
    /// dominant language. Never returns nil once a project is indexed.
    public static func effective(projectRoot root: URL) -> ProjectRules {
        if let saved = load(projectRoot: root) { return saved }
        if let store = try? Indexer.openStore(forProjectRoot: root),
           let dominant = try? store.fileCountByLanguage()
               .filter({ $0.key != .unknown })
               .max(by: { $0.value < $1.value })?.key {
            return ProjectRules(language: dominant.displayName)
        }
        return ProjectRules()
    }
}
