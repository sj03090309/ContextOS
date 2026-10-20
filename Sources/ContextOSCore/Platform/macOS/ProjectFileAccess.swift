import Foundation
import Darwin

/// Project-relative reads walk directory descriptors with O_NOFOLLOW, so a
/// link swapped in after scanning cannot redirect a source/rule read. Opening
/// a special file is nonblocking; fstat then rejects everything but regular files.
struct ProjectFileAccess {
    let root: URL

    init(root: URL) throws {
        // Foundation preserves macOS aliases such as /var even after
        // resolvingSymlinksInPath(). POSIX realpath is needed for SQLite's
        // NOFOLLOW mode and for descriptor opens on these system aliases.
        guard let path = Darwin.realpath(root.path, nil) else { throw CocoaError(.fileReadNoSuchFile) }
        defer { free(path) }
        self.root = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        guard !SensitiveFilePolicy.isSensitiveRoot(self.root),
              (try? self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    func read(_ relativePath: String, maximumBytes: Int = 2_000_000) throws -> Data {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard maximumBytes > 0, !relativePath.contains("\\"), !relativePath.contains("\0"),
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !SensitiveFilePolicy.isSensitivePath(relativePath) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = Darwin.openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = Darwin.openat(directory, components.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CocoaError(.fileReadNoPermission)
        }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumBytes - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumBytes else { throw CocoaError(.fileReadNoPermission) }
            data.append(chunk)
        }
        return data
    }

    /// SQLite opens the database and sidecars itself. Refuse pre-existing links
    /// or special files before it gets any pathname, including a linked index dir.
    func indexURL() throws -> URL {
        let manager = FileManager.default
        let directory = root.appendingPathComponent(".contextos", isDirectory: true)
        for name in [".contextos", ".contextos/index.sqlite", ".contextos/index.sqlite-wal", ".contextos/index.sqlite-shm", ".contextos/index.sqlite-journal", ".contextos/.gitignore"] {
            let url = root.appendingPathComponent(name)
            do {
                let attributes = try manager.attributesOfItem(atPath: url.path)
                let expected: FileAttributeType = name == ".contextos" ? .typeDirectory : .typeRegular
                guard attributes[.type] as? FileAttributeType == expected else { throw CocoaError(.fileReadNoPermission) }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
        }
        return directory.appendingPathComponent("index.sqlite")
    }
}
