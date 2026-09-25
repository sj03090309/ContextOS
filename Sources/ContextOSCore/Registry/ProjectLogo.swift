import Foundation

/// Finds the image a project uses as its own logo — its app icon, favicon or
/// logo file — so the dashboard can show that instead of a letter.
///
/// Conventional places are checked first, then a shallow search that skips
/// dependency and build folders, so a monorepo's `frontend/public/favicon.ico`
/// is found without walking `node_modules`. Nothing is decoded here: this only
/// names a file, and the app decides whether it can draw it.
public enum ProjectLogo {

    /// Paths that are a project's logo by convention, best first.
    static let conventional = [
        "AppIcon.icns",
        "assets/icon.png", "assets/logo.png", "icon.png", "logo.png",
        "public/apple-touch-icon.png", "public/logo512.png", "public/logo192.png",
        "public/icon.png", "public/logo.png",
        "app/apple-icon.png", "app/icon.png", "src/app/apple-icon.png", "src/app/icon.png",
        "static/logo.png", "static/icon.png", "resources/icon.png", "build/icon.png",
        "public/favicon.png", "public/favicon.ico", "app/favicon.ico", "src/app/favicon.ico",
        "static/favicon.ico", "favicon.ico",
        "public/favicon.svg", "public/logo.svg", "logo.svg", "assets/logo.svg", "icon.svg"
    ]

    /// File names worth picking up a few levels down, ranked: big, deliberate
    /// icons before 16px favicons, raster before SVG.
    static let ranked: [String: Int] = [
        "AppIcon.icns": 0, "apple-touch-icon.png": 0, "logo512.png": 1,
        "icon.png": 2, "logo.png": 2, "apple-icon.png": 2, "logo192.png": 3,
        "favicon.png": 4, "favicon.ico": 5,
        "icon.svg": 6, "logo.svg": 6, "favicon.svg": 7
    ]

    /// Folders that hold other people's files, or build output, never the
    /// project's own logo.
    static let skipped: Set<String> = [
        "node_modules", ".git", ".build", "build", "dist", "out", "DerivedData", "Pods",
        "vendor", ".next", "target", ".venv", "venv", "__pycache__", "coverage",
        ".turbo", ".cache", "Carthage", ".gradle", "tmp"
    ]

    /// The best logo file in `root`, or nil when the project has none.
    public static func find(in root: URL, maxDepth: Int = 3) -> URL? {
        let fm = FileManager.default
        for relative in conventional {
            let url = root.appendingPathComponent(relative)
            if isFile(url) { return url }
        }

        var best: (url: URL, rank: Int, depth: Int)?
        func consider(_ url: URL, rank: Int, depth: Int) {
            if best == nil || (rank, depth) < (best!.rank, best!.depth) { best = (url, rank, depth) }
        }
        var queue: [(URL, Int)] = [(root, 0)]
        var visited = 0
        // Bounded twice over — by depth and by directories read — so a huge
        // tree costs a few milliseconds at most.
        while !queue.isEmpty, visited < 400 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDirectory {
                    if name == "AppIcon.appiconset", let largest = largestPNG(in: entry) {
                        consider(largest, rank: 0, depth: depth)
                    } else if depth < maxDepth || name.hasSuffix(".xcassets"), !skipped.contains(name),
                              !name.hasSuffix(".app"), !name.hasSuffix(".framework") {
                        queue.append((entry, depth + 1))
                    }
                } else if let rank = ranked[name] {
                    consider(entry, rank: rank, depth: depth)
                }
            }
        }
        return best?.url
    }

    /// An Xcode icon set holds one PNG per size; the biggest draws best.
    private static func largestPNG(in iconSet: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: iconSet, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "png" }
            .max { size($0) < size($1) }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
