import Foundation

/// Decides which paths are worth indexing.
///
/// This is the "Smart File Filter" from the spec: a strong default deny-list
/// (node_modules, .git, build artifacts, …) plus binary detection. The scanner
/// layers the project's root `.gitignore` on top via `GitignoreMatcher`.
public struct FileFilter: Sendable {

    /// Directory names that are excluded wholesale, at any depth.
    public var ignoredDirectories: Set<String>

    /// File name suffixes that are excluded (lowercased).
    public var ignoredFileSuffixes: Set<String>

    /// Exact file names that are excluded.
    public var ignoredFileNames: Set<String>

    /// Files larger than this (bytes) are skipped as likely generated/vendored.
    public var maxFileSize: Int

    public init(
        ignoredDirectories: Set<String> = FileFilter.defaultIgnoredDirectories,
        ignoredFileSuffixes: Set<String> = FileFilter.defaultIgnoredFileSuffixes,
        ignoredFileNames: Set<String> = FileFilter.defaultIgnoredFileNames,
        maxFileSize: Int = 2_000_000
    ) {
        self.ignoredDirectories = ignoredDirectories
        self.ignoredFileSuffixes = ignoredFileSuffixes
        self.ignoredFileNames = ignoredFileNames
        self.maxFileSize = maxFileSize
    }

    /// True if a directory (by name) should be skipped entirely.
    public func shouldSkipDirectory(named name: String) -> Bool {
        if name.hasPrefix(".") && name != "." {
            // Hidden dirs are noise for indexing (.git, .cache, .venv, …),
            // with a couple of exceptions worth keeping.
            if FileFilter.keptHiddenDirectories.contains(name) { return false }
            return true
        }
        return ignoredDirectories.contains(name)
    }

    /// True if a file should be skipped, based on name only (cheap pre-check).
    public func shouldSkipFile(named name: String) -> Bool {
        if ignoredFileNames.contains(name) { return true }
        let lower = name.lowercased()
        for suffix in ignoredFileSuffixes where lower.hasSuffix(suffix) {
            return true
        }
        return false
    }

    // MARK: - Defaults

    public static let defaultIgnoredDirectories: Set<String> = [
        "node_modules", "bower_components", "vendor",
        "build", "dist", "out", "target",
        "DerivedData", ".build", "Pods", "Carthage",
        "coverage", "__pycache__", ".pytest_cache",
        "logs", "tmp", "temp",
        ".next", ".nuxt", ".svelte-kit",
        "venv", "env", ".gradle", ".idea", ".vscode"
    ]

    /// Hidden directories we deliberately keep despite the "skip hidden" rule.
    public static let keptHiddenDirectories: Set<String> = [
        ".github"
    ]

    public static let defaultIgnoredFileSuffixes: Set<String> = [
        // Binaries / archives
        ".o", ".a", ".so", ".dylib", ".dll", ".exe", ".bin", ".class",
        ".zip", ".tar", ".gz", ".7z", ".rar",
        // Images / media
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".icns",
        ".svg", ".pdf", ".mp4", ".mov", ".mp3", ".wav",
        // Fonts
        ".ttf", ".otf", ".woff", ".woff2",
        // Lock / generated
        ".lock", ".min.js", ".min.css", ".map",
        // Data blobs
        ".sqlite", ".db", ".pyc"
    ]

    public static let defaultIgnoredFileNames: Set<String> = [
        ".DS_Store", "package-lock.json", "yarn.lock",
        "pnpm-lock.yaml", "Package.resolved"
    ]
}
