import Foundation
import CWindowsNative

enum WindowsNativeError: Int32, Error, LocalizedError {
    case unavailable = 1, invalidPath, unsafeObject, io, tooLarge, privateACLRequired, locked, alreadyExists
    var errorDescription: String? {
        switch self {
        case .unavailable: "Windows native primitives are unavailable on this host."
        case .invalidPath: "The path is outside the supported Windows namespace."
        case .unsafeObject: "A link, reparse point, hardlink, remote volume or unsafe file was refused."
        case .io: "The protected Windows operation could not complete."
        case .tooLarge: "The file exceeds the permitted read budget."
        case .privateACLRequired: "A protected ACL owned exclusively by the current user is required."
        case .locked: "The private lock is already held."
        case .alreadyExists: "The destination exists; its contents were preserved."
        }
    }
    static func check(_ status: Int32) throws {
        if status != 0 { throw Self(rawValue: status) ?? .io }
    }
}

/// Internal candidate adapter. Production entry points remain blocked by
/// RuntimeSupport until real Windows security and integration tests pass.
final class WindowsNativeRoot {
    private let handle: OpaquePointer
    static var compiledForHost: Bool { cosw_available() != 0 }

    init(localPath: String) throws {
        let path = try WindowsPathPolicy.localRoot(localPath)
        var opened: OpaquePointer?
        try WindowsNativeError.check(path.withCString { cosw_root_open($0, &opened) })
        guard let opened else { throw WindowsNativeError.io }
        handle = opened
    }
    private init(handle: OpaquePointer) { self.handle = handle }
    deinit { cosw_root_close(handle) }

    func read(relativePath: String, byteLimit: Int = 8 * 1024 * 1024) throws -> Data {
        let path = try WindowsPathPolicy.relative(relativePath)
        guard byteLimit > 0 else { throw WindowsNativeError.invalidPath }
        var bytes: UnsafeMutableRawPointer?, count = 0
        try WindowsNativeError.check(path.withCString { cosw_root_read(handle, $0, byteLimit, &bytes, &count) })
        guard let bytes else { throw WindowsNativeError.io }
        defer { cosw_buffer_free(bytes) }
        return Data(bytes: bytes, count: count)
    }

    func createPrivateDirectory(name: String) throws -> WindowsNativeRoot {
        let name = try WindowsPathPolicy.singleName(name)
        var opened: OpaquePointer?
        try WindowsNativeError.check(name.withCString { cosw_private_directory_create(handle, $0, &opened) })
        guard let opened else { throw WindowsNativeError.io }
        return WindowsNativeRoot(handle: opened)
    }

    /// Create-only primitive; deliberately does not replace settings or backups.
    func writeNewPrivateFile(name: String, data: Data) throws {
        let name = try WindowsPathPolicy.singleName(name)
        let status = name.withCString { fileName in
            data.withUnsafeBytes { cosw_private_write_new(handle, fileName, $0.baseAddress, $0.count) }
        }
        try WindowsNativeError.check(status)
    }

    func acquirePrivateLock(name: String) throws -> WindowsNativeLock {
        let name = try WindowsPathPolicy.singleName(name)
        var opened: OpaquePointer?
        try WindowsNativeError.check(name.withCString { cosw_lock_acquire(handle, $0, &opened) })
        guard let opened else { throw WindowsNativeError.io }
        return WindowsNativeLock(handle: opened)
    }

    static func sha256(_ data: Data) throws -> Data {
        var digest = [UInt8](repeating: 0, count: 32)
        let status = digest.withUnsafeMutableBufferPointer { output in
            data.withUnsafeBytes { cosw_sha256($0.baseAddress, $0.count, output.baseAddress) }
        }
        try WindowsNativeError.check(status)
        return Data(digest)
    }
}

final class WindowsNativeLock {
    private var handle: OpaquePointer?
    fileprivate init(handle: OpaquePointer) { self.handle = handle }
    func release() {
        if let opened = handle { cosw_lock_release(opened); handle = nil }
    }
    deinit { release() }
}
