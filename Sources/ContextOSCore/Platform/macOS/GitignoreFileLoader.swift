import Foundation

extension GitignoreMatcher {
    /// File loading belongs to the protected platform adapter; pattern matching
    /// remains available without a filesystem implementation.
    public static func load(projectRoot: URL) -> GitignoreMatcher? {
        guard let data = try? ProjectFileAccess(root: projectRoot).read(".gitignore"),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let matcher = GitignoreMatcher(patterns: text.components(separatedBy: "\n"))
        return matcher.isEmpty ? nil : matcher
    }
}
