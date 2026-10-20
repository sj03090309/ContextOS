import Foundation
import CoreServices

/// Coalesced FSEvents over project roots. Index output, credential files and
/// build noise cannot trigger a self-sustaining re-index loop.
public final class FileWatcher: @unchecked Sendable {
    private var stream: FileEventStream?
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private static let filter = FileFilter()

    public init(paths: [String], latency: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        self.latency = latency
        self.onChange = onChange
    }
    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        if stream != nil { return true }
        let stream = FileEventStream(paths: paths, latency: latency) { [paths, onChange] events in
            if events.contains(where: { $0.requiresRescan || Self.shouldReindex(path: $0.path, roots: paths,
                isDirectory: $0.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0) }) {
                onChange()
            }
        }
        guard stream.start() else { return false }
        self.stream = stream
        return true
    }
    public func stop() { stream?.stop(); stream = nil }

    public static func shouldReindex(path: String, roots: [String], isDirectory: Bool = false) -> Bool {
        var path = path
        var root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") })
        // FSEvents normally supplies an already absolute path. Only normalize
        // aliases when the root did not match; avoid allocating a URL per event.
        if root == nil || path.contains("/../") || path.contains("/./") {
            path = URL(fileURLWithPath: path).standardizedFileURL.path
            root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") })
        }
        guard let root else { return false }
        if path == root { return true }
        let relative = String(path.dropFirst(root.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: filter.shouldSkipDirectory) { return false }
        if SensitiveFilePolicy.isSensitivePath(relative) { return false }
        guard let name = parts.last else { return true }
        if isDirectory { return !filter.shouldSkipDirectory(named: name) }
        if name == ".gitignore" { return true } // changed ignore rules invalidate the index
        if name == ".contextos" || name == ".git" { return false }
        return !filter.shouldSkipFile(named: name)
    }
}
