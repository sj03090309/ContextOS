import Foundation
import CoreServices

/// A file-level FSEvents stream that hands its batches over as they arrive.
///
/// `FileWatcher` answers "did anything change?" for the re-indexer; this one
/// keeps the paths and flags, for callers that care *which* file was written —
/// the menu-bar app learns an agent is working from the exact session log that
/// changed, instead of re-listing every log directory on a timer.
public final class FileEventStream: @unchecked Sendable {

    public struct Event: Sendable {
        public var path: String
        public var flags: FSEventStreamEventFlags

        /// FSEvents lost track of what changed under `path` — events were
        /// dropped, or a watched root was moved or replaced — so a caller that
        /// keeps state derived from the tree must rebuild it from scratch.
        public var requiresRescan: Bool {
            let lost = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            return flags & FSEventStreamEventFlags(lost) != 0
        }
    }

    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable ([Event]) -> Void

    /// - Parameters:
    ///   - paths: directory trees to watch.
    ///   - latency: how long FSEvents may hold events back to coalesce them. The
    ///     first event after a quiet spell is still delivered at once.
    ///   - handler: called on a private utility queue with each batch.
    public init(paths: [String], latency: TimeInterval = 1.0,
                handler: @escaping @Sendable ([Event]) -> Void) {
        self.paths = paths
        self.latency = latency
        self.handler = handler
        self.queue = DispatchQueue(label: "contextos.file-events", qos: .utility)
    }

    deinit { stop() }

    /// Start watching. False if the stream could not be created — the caller
    /// should fall back to polling.
    @discardableResult
    public func start() -> Bool {
        guard stream == nil else { return true }
        guard !paths.isEmpty else { return false }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let owner = Unmanaged<FileEventStream>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var events: [Event] = []
            events.reserveCapacity(count)
            for index in 0..<min(count, paths.count) {
                events.append(Event(path: paths[index], flags: eventFlags[index]))
            }
            owner.handler(events)
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency, flags
        ) else { return false }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
