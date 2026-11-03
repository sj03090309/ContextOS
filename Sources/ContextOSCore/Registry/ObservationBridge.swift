import Foundation
import Darwin
import CoreFoundation
import ContextOSUsage

public struct ObservationPacket: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case focus, edits, activity, heartbeat, gap }
    public var version: Int
    public var editor: String
    public var nonce: String
    public var sequence: Int64
    public var kind: Kind
    public var focused: Bool?
    public var count: Int?
    public var activity: String?
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { throw BridgeError.invalidPacket }
        let v2 = (object["version"] as? NSNumber)?.intValue == 2
        let extra = kind == "focus" ? ["focused"] : kind == "edits" ? (v2 ? ["count","focused"] : ["count"]) : kind == "activity" && v2 ? ["activity","focused"] : []
        let keys = Set(["version", "editor", "nonce", "sequence", "kind"] + extra)
        guard Set(object.keys) == keys else { throw BridgeError.invalidPacket }
        for name in ["version", "sequence"] + (kind == "edits" ? ["count"] : []) {
            guard let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw BridgeError.invalidPacket }
        }
        if kind == "focus" || (v2 && ["edits","activity"].contains(kind)) {
            guard let value = object["focused"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw BridgeError.invalidPacket }
        }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        guard [1,2].contains(packet.version), ["vscode", "vscode-insiders"].contains(packet.editor),
              UUID(uuidString: packet.nonce) != nil, packet.sequence > 0, packet.sequence <= Int32.max,
              packet.kind != .edits || (1...256).contains(packet.count ?? 0),
              packet.kind != .activity || (packet.version == 2 && ["selection","scroll"].contains(packet.activity ?? "")) else { throw BridgeError.invalidPacket }
        return packet
    }
}
/// A receiver generation owns persistence only after its socket is ready.
public struct ObservationReceiverLease: Sendable {
    private var generation = UUID()
    public private(set) var isReady = false
    public init() {}
    public mutating func begin() -> UUID { generation = UUID(); isReady = false; return generation }
    public func accepts(_ value: UUID) -> Bool { generation == value }
    @discardableResult public mutating func ready(_ value: UUID) -> Bool {
        guard accepts(value) else { return false }; isReady = true; return true
    }
    public mutating func invalidate() { generation = UUID(); isReady = false }
}

public enum BridgeError: Error { case invalidPacket, unsafeLocation, socketFailure }
public enum ObservationBridgeEvent: Sendable { case ready, packet(ObservationPacket), disconnected(String?), failed }

/// In-memory counts only. Nonce/sequence/focus are never converted into time.
public struct ObservationBridgeLedger: Sendable {
    public private(set) var editCount: UInt64?
    public private(set) var focused: Bool?
    public private(set) var partial = false
    private var nonce: String?
    private var sequence: Int64 = 0
    public init() {}
    public mutating func consume(_ packet: ObservationPacket) {
        if nonce != packet.nonce {
            if nonce != nil { partial = true }
            nonce = packet.nonce; sequence = 0; focused = nil
        }
        guard packet.sequence > sequence else { return }
        if packet.sequence != sequence + 1 { partial = true }
        sequence = packet.sequence
        switch packet.kind {
        case .focus: focused = packet.focused
        case .edits:
            let (sum, overflow) = (editCount ?? 0).addingReportingOverflow(UInt64(packet.count ?? 0))
            editCount = overflow ? .max : sum; partial = partial || overflow
        case .gap: partial = true
        case .activity, .heartbeat: break
        }
    }
    public mutating func disconnect() { focused = nil; partial = true; nonce = nil; sequence = 0 }
}

/// Disabled until the UI explicitly opts in. Same-user private Unix socket,
/// no TCP/network endpoint or raw packet log. Only a proven stale, private,
/// same-user socket may be recovered while holding the receiver lease.
public final class ObservationBridgeServer: @unchecked Sendable {
    private final class Client {
        var fd: Int32
        var source: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var buffer = Data()
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var packetCount = 0
        var nonce: String?
        init(_ fd: Int32) { self.fd = fd }
    }
    private let queue = DispatchQueue(label: "contextos.observation-bridge", qos: .utility)
    private let callback: @Sendable (ObservationBridgeEvent) -> Void
    private var listener: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var leaseFD: Int32 = -1
    private var clients: [Int32: Client] = [:]
    private var ownedPath: String?
    private var ownedInode: ino_t?
    public init(callback: @escaping @Sendable (ObservationBridgeEvent) -> Void) { self.callback = callback }
    public func start(directory: URL) { queue.async { self.open(directory) } }
    public func publish(_ snapshot: EstimatedActivitySnapshot) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        guard var bytes = try? encoder.encode(snapshot), bytes.count <= 1024 else { return }
        bytes.append(10)
        let frame = bytes
        queue.async {
            for fd in Array(self.clients.keys) {
                let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                if n != frame.count { self.drop(fd) } // Bound output; never buffer a backlog.
            }
        }
    }
    public func stop() { queue.async { self.shutdown() } }
    /// App termination cleanup; callbacks never synchronously wait for the main queue.
    public func stopSynchronously() { queue.sync { self.shutdown() } }
    private func open(_ directory: URL) {
        guard socketFD == -1 else { return }
        do {
            let fm = FileManager.default
            var status = stat()
            if lstat(directory.path, &status) != 0 {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                guard lstat(directory.path, &status) == 0 else { throw BridgeError.unsafeLocation }
            }
            guard status.st_uid == getuid(), (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_mode & 0o077 == 0 else { throw BridgeError.unsafeLocation }
            // Keep this lock inode permanently: unlinking a lock file can let
            // two processes acquire locks on different inodes at the same path.
            let lockPath = directory.appendingPathComponent("receiver.lock").path
            let lockFD = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lockFD >= 0 else { throw BridgeError.unsafeLocation }
            leaseFD = lockFD
            guard fstat(lockFD, &status) == 0, status.st_uid == getuid(),
                  status.st_mode & S_IFMT == S_IFREG, status.st_mode & 0o077 == 0,
                  status.st_nlink == 1, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError.unsafeLocation }
            let path = directory.appendingPathComponent("observations.sock").path
            guard path.utf8.count < 104 else { throw BridgeError.unsafeLocation }
            try recoverStaleSocket(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw BridgeError.socketFailure }
            socketFD = fd
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
            }
            let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw BridgeError.socketFailure }
            ownedPath = path
            if lstat(path, &status) == 0 { ownedInode = status.st_ino }
            guard chmod(path, 0o600) == 0, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw BridgeError.socketFailure }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            listener = source; source.setEventHandler { [weak self] in self?.acceptClients() }; callback(.ready); source.resume()
        } catch { shutdown(); callback(.failed) }
    }
    private func recoverStaleSocket(_ path: String) throws {
        var before = stat()
        guard lstat(path, &before) == 0 else {
            guard errno == ENOENT else { throw BridgeError.unsafeLocation }; return
        }
        guard before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFSOCK,
              before.st_mode & 0o077 == 0 else { throw BridgeError.unsafeLocation }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw BridgeError.socketFailure }
        defer { close(probe) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.utf8CString.withUnsafeBytes { bytes.copyBytes(from: $0) }
        }
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // A live listener, access failure, or any ambiguous result is preserved.
        guard result == -1, errno == ECONNREFUSED else { throw BridgeError.unsafeLocation }
        var after = stat()
        guard lstat(path, &after) == 0, before.st_dev == after.st_dev,
              before.st_ino == after.st_ino, after.st_uid == getuid(),
              after.st_mode & S_IFMT == S_IFSOCK, after.st_mode & 0o077 == 0,
              unlink(path) == 0 else { throw BridgeError.unsafeLocation }
    }
    private func acceptClients() {
        while true {
            let fd = accept(socketFD, nil, nil)
            guard fd >= 0 else { break }
            var uid: uid_t = 0, gid: gid_t = 0
            guard clients.count < 4, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); continue }
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd); clients[fd] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            client.source = source; source.setEventHandler { [weak self] in self?.readClient(fd) }; source.resume()
            resetTimeout(client, seconds: 75)
        }
    }
    private func resetTimeout(_ client: Client, seconds: Int) {
        client.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue); client.timer = timer
        timer.schedule(deadline: .now() + .seconds(seconds))
        let fd = client.fd
        timer.setEventHandler { [weak self] in self?.drop(fd) }; timer.resume()
    }
    private func readClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var bytes = [UInt8](repeating: 0, count: 1024)
        // One bounded read per dispatch turn, at most four complete packets.
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n == 0 { drop(fd); return }
        if n < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { drop(fd) }; return }
        client.buffer.append(contentsOf: bytes.prefix(n))
        var packets = 0
        while let newline = client.buffer.firstIndex(of: 10) {
            packets += 1
            let tick = DispatchTime.now().uptimeNanoseconds
            if tick - client.windowStart >= 1_000_000_000 { client.windowStart = tick; client.packetCount = 0 }
            client.packetCount += 1
            guard client.packetCount <= 64 else { drop(fd); return }
            guard packets <= 4 else { drop(fd); return }
            let frame = client.buffer.prefix(upTo: newline)
            do {
                let packet = try ObservationPacket.decode(Data(frame))
                guard client.nonce == nil || client.nonce == packet.nonce else { drop(fd); return }
                client.nonce = packet.nonce; callback(.packet(packet))
            }
            catch { drop(fd); return }
            client.buffer.removeSubrange(...newline)
        }
        guard client.buffer.count <= 1024 else { drop(fd); return }
        resetTimeout(client, seconds: client.buffer.isEmpty ? 75 : 5)
    }
    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source?.cancel(); client.timer?.cancel(); close(fd); callback(.disconnected(client.nonce))
    }
    private func shutdown() {
        for fd in Array(clients.keys) { drop(fd) }
        listener?.cancel(); listener = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        if let path = ownedPath {
            var status = stat()
            if lstat(path, &status) == 0, status.st_ino == ownedInode, (status.st_mode & S_IFMT) == S_IFSOCK { unlink(path) }
            ownedPath = nil; ownedInode = nil
        }
        if leaseFD >= 0 { close(leaseFD); leaseFD = -1 }
    }
}
