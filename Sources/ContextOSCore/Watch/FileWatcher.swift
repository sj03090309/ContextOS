import Foundation
import CoreServices

/// Watches a directory tree and fires a debounced callback when source files
/// change — the foundation of ContextOS's automation (auto re-index).
///
/// Ignores ContextOS's own artifacts (`.contextos/`) and noise dirs so writing
/// the index never re-triggers itself.
public final class FileWatcher: @unchecked Sendable {

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "contextos.filewatcher")

    private static let ignoredFragments = [
        "/.contextos/", "/.git/", "/node_modules/", "/.build/",
        "/DerivedData/", "/dist/", "/.next/", "/__pycache__/"
    ]

    public init(paths: [String], latency: TimeInterval = 2.0, onChange: @escaping @Sendable () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        guard stream == nil else { return }

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ changedPaths: [String]) {
        let relevant = changedPaths.contains { path in
            !Self.ignoredFragments.contains { path.contains($0) }
        }
        if relevant { onChange() }
    }
}
