import Foundation

/// A filesystem file discovered during a scan, before its content is read.
public struct ScannedFile: Sendable {
    public var absoluteURL: URL
    public var relativePath: String
    public var language: Language
    public var byteSize: Int
    public var modifiedAt: Double
}

/// Walks a project tree, pruning ignored directories, and yields candidate files.
public struct ProjectScanner: Sendable {

    public let filter: FileFilter

    public init(filter: FileFilter = FileFilter()) {
        self.filter = filter
    }

    /// Recursively scan `root`, returning files worth indexing.
    ///
    /// Directories that match the filter are pruned wholesale (never descended
    /// into), which is what keeps `node_modules`-style trees cheap.
    public func scan(root: URL) throws -> [ScannedFile] {
        let fm = FileManager.default
        let scanRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = scanRoot.path
        guard !SensitiveFilePolicy.isSensitiveRoot(scanRoot) else { throw CocoaError(.fileReadNoPermission) }
        var results: [ScannedFile] = []

        // Explicit stack so we control directory pruning precisely.
        struct IgnoreScope { var prefix: String; var matcher: GitignoreMatcher }
        var stack: [(URL, [IgnoreScope])] = [(scanRoot, [])]

        while let (dir, inherited) = stack.popLast() {
            var scopes = inherited
            if let matcher = GitignoreMatcher.load(projectRoot: dir) {
                let relative = Self.relativePath(of: dir.standardizedFileURL.path, root: rootPath)
                scopes.append(IgnoreScope(prefix: relative.isEmpty ? "" : relative + "/", matcher: matcher))
            }
            func ignored(_ path: String, isDirectory: Bool) -> Bool {
                var ignored = false
                for scope in scopes where path.hasPrefix(scope.prefix) {
                    if let decision = scope.matcher.decision(String(path.dropFirst(scope.prefix.count)), isDirectory: isDirectory) {
                        ignored = decision
                    }
                }
                return ignored
            }
            let entries: [URL]
            do {
                // Include hidden entries so the filter can decide (e.g. keep .github,
                // drop .git). Hidden-dir pruning happens in `shouldSkipDirectory`.
                entries = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                                .fileSizeKey, .contentModificationDateKey],
                    options: []
                )
            } catch {
                if dir.standardizedFileURL == scanRoot { throw error }
                continue // unreadable directory — skip, don't abort the whole scan
            }

            for entry in entries {
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                              .fileSizeKey, .contentModificationDateKey]
                )
                // Avoid reading outside the root, directory cycles, duplicate
                // aliases, and special files whose reads could block forever.
                guard let values, values.isSymbolicLink != true else { continue }
                let isDir = values.isDirectory ?? false
                let name = entry.lastPathComponent

                // Standardize the entry the same way as the root, so /tmp vs
                // /private/tmp (and similar symlinks) don't break the prefix match.
                let relative = Self.relativePath(of: entry.standardizedFileURL.path, root: rootPath)

                if isDir {
                    if filter.shouldSkipDirectory(named: name) { continue }
                    if ignored(relative, isDirectory: true) { continue }
                    stack.append((entry, scopes))
                    continue
                }

                guard values.isRegularFile == true else { continue }

                if filter.shouldSkipFile(named: name) { continue }
                if SensitiveFilePolicy.isSensitivePath(relative) { continue }
                if ignored(relative, isDirectory: false) { continue }

                let size = values.fileSize ?? 0
                if size > filter.maxFileSize { continue }

                let ext = entry.pathExtension
                let language = Language.detect(fromExtension: ext)

                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

                results.append(
                    ScannedFile(
                        absoluteURL: entry,
                        relativePath: relative,
                        language: language,
                        byteSize: size,
                        modifiedAt: mtime
                    )
                )
            }
        }

        results.sort { $0.relativePath < $1.relativePath }
        return results
    }

    private static func relativePath(of path: String, root: String) -> String {
        if path.hasPrefix(root) {
            let dropped = path.dropFirst(root.count)
            return dropped.hasPrefix("/") ? String(dropped.dropFirst()) : String(dropped)
        }
        return path
    }
}
