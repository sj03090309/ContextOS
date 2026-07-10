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
        let rootPath = root.standardizedFileURL.path
        let gitignore = GitignoreMatcher.load(projectRoot: root)
        var results: [ScannedFile] = []

        // Explicit stack so we control directory pruning precisely.
        var stack: [URL] = [root.standardizedFileURL]

        while let dir = stack.popLast() {
            let entries: [URL]
            do {
                // Include hidden entries so the filter can decide (e.g. keep .github,
                // drop .git). Hidden-dir pruning happens in `shouldSkipDirectory`.
                entries = try fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: []
                )
            } catch {
                continue // unreadable directory — skip, don't abort the whole scan
            }

            for entry in entries {
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                )
                let isDir = values?.isDirectory ?? false
                let name = entry.lastPathComponent

                // Standardize the entry the same way as the root, so /tmp vs
                // /private/tmp (and similar symlinks) don't break the prefix match.
                let relative = Self.relativePath(of: entry.standardizedFileURL.path, root: rootPath)

                if isDir {
                    if filter.shouldSkipDirectory(named: name) { continue }
                    if let gitignore, gitignore.isIgnored(relative, isDirectory: true) { continue }
                    stack.append(entry)
                    continue
                }

                if filter.shouldSkipFile(named: name) { continue }
                if let gitignore, gitignore.isIgnored(relative, isDirectory: false) { continue }

                let size = values?.fileSize ?? 0
                if size > filter.maxFileSize { continue }

                let ext = entry.pathExtension
                let language = Language.detect(fromExtension: ext)

                let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0

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
