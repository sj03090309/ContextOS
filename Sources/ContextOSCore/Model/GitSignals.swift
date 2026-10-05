/// Supplied ranking signals. Collecting Git state remains platform-specific.
public struct GitSignals: Sendable {
    /// Files with uncommitted changes in the working tree.
    public var changedPaths: Set<String>
    /// Files touched by recent commits.
    public var recentPaths: Set<String>

    public static let empty = GitSignals(changedPaths: [], recentPaths: [])

    public var isEmpty: Bool { changedPaths.isEmpty && recentPaths.isEmpty }
}
