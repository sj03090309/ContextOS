import Foundation

/// The shared list of projects ContextOS tracks, stored as a JSON file both the
/// CLI (`contextos setup`) and the menu-bar app read/write.
///
/// Lives next to the usage DB in Application Support so it's independent of any
/// single project and survives re-indexing.
public enum ProjectRegistry {

    public static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("ContextOS", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    public static func hiddenFileURL() -> URL {
        fileURL().deletingLastPathComponent().appendingPathComponent("hidden-projects.json")
    }

    public static func list() -> [String] {
        guard let data = try? Data(contentsOf: fileURL()),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        let hidden = Set(hiddenList())
        return paths.filter { !hidden.contains($0) }
    }

    public static func save(_ paths: [String]) {
        let url = fileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(paths).write(to: url)
    }

    public static func hiddenList() -> [String] {
        guard let data = try? Data(contentsOf: hiddenFileURL()),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return paths
    }

    public static func saveHidden(_ paths: [String]) {
        let url = hiddenFileURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try? encoder.encode(paths).write(to: url)
    }

    @discardableResult
    public static func add(_ path: String) -> [String] {
        var paths = list()
        if !paths.contains(path) { paths.append(path) }
        saveHidden(hiddenList().filter { $0 != path })
        save(paths)
        return paths
    }

    @discardableResult
    public static func remove(_ path: String) -> [String] {
        let paths = list().filter { $0 != path }
        var hidden = hiddenList()
        if !hidden.contains(path) { hidden.append(path) }
        saveHidden(hidden)
        save(paths)
        return paths
    }

    /// Files/dirs whose presence marks a directory as a project root.
    static let markers: Set<String> = [
        ".git", "Package.swift", "package.json", "pyproject.toml",
        "requirements.txt", "Cargo.toml", "go.mod", "pom.xml",
        "build.gradle", "Gemfile", "composer.json"
    ]

    /// Directories never worth descending into during discovery.
    private static let skipDirs: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Library",
        "Applications", ".Trash", "Pods", "vendor", "venv", ".venv",
        "dist", "build", "target", "__pycache__",
        "Downloads", "Movies", "Music", "Pictures", "Public", "Desktop.bak"
    ]

    /// Discover project roots under `roots`, up to `maxDepth` deep. A directory
    /// containing any marker is a project root and is not descended into.
    public static func discover(roots: [URL], maxDepth: Int = 3) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()

        func markerPresent(in dir: URL) -> Bool {
            for m in markers where fm.fileExists(atPath: dir.appendingPathComponent(m).path) {
                return true
            }
            return false
        }

        func walk(_ dir: URL, depth: Int) {
            let name = dir.lastPathComponent
            if depth > 0, skipDirs.contains(name) || (name.hasPrefix(".") && name != ".") { return }

            if markerPresent(in: dir) {
                let path = dir.standardizedFileURL.path
                if seen.insert(path).inserted { found.append(path) }
                return // don't descend into a discovered project
            }
            guard depth < maxDepth else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                walk(entry, depth: depth + 1)
            }
        }

        for root in roots { walk(root.standardizedFileURL, depth: 0) }
        return found.sorted()
    }

    /// The default roots to scan: the home directory plus common dev locations.
    public static func defaultScanRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sub = ["Desktop", "Documents", "Developer", "Projects", "Documents/GitHub", "src", "code"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return [home] + sub
    }
}
