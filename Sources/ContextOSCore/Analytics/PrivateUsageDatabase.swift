import Foundation
import Darwin

/// Usage records contain search requests and project paths. Create the database
/// privately before SQLite opens it, and refuse links/special files rather than
/// changing permissions on a file outside this analytics store.
enum PrivateUsageDatabase {
    static func prepare(path: String) throws -> String {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw IndexStoreError.open("Unsafe analytics directory") }
        defer { Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR else { throw IndexStoreError.open("Unsafe analytics directory") }
        // Only narrow the app-owned standard directory. Custom fixture/API
        // parents may contain unrelated files and keep their original mode.
        if parent == UsageStore.defaultURL().deletingLastPathComponent() {
            guard fchmod(directory, 0o700) == 0 else { throw IndexStoreError.open("Cannot protect analytics directory") }
        } else if info.st_mode & 0o022 != 0 {
            throw IndexStoreError.open("Analytics directory is writable by another user")
        }
        try protect(file.lastPathComponent, in: directory, create: true)
        for suffix in ["-wal", "-shm", "-journal"] {
            try protect(file.lastPathComponent + suffix, in: directory, create: false)
        }
        guard let canonical = realpath(parent.path, nil) else { throw IndexStoreError.open("Cannot resolve analytics directory") }
        defer { free(canonical) }
        return String(cString: canonical) + "/" + file.lastPathComponent
    }

    private static func protect(_ name: String, in directory: Int32, create: Bool) throws {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0)
        let file = openat(directory, name, flags, mode_t(0o600))
        if file < 0, !create, errno == ENOENT { return }
        guard file >= 0 else { throw IndexStoreError.open("Unsafe analytics database or sidecar") }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              fchmod(file, 0o600) == 0 else {
            throw IndexStoreError.open("Unsafe analytics database or sidecar")
        }
    }
}
