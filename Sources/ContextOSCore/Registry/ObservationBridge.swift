import Foundation
import Darwin
import CoreFoundation

public struct ObservationPacket: Decodable, Sendable {
    public enum Kind: String, Decodable, Sendable { case focus, edits, heartbeat, gap }
    public var version: Int
    public var editor: String
    public var nonce: String
    public var sequence: Int64
    public var kind: Kind
    public var focused: Bool?
    public var count: Int?
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { throw BridgeError.invalidPacket }
        let keys = Set(["version", "editor", "nonce", "sequence", "kind"] + (kind == "focus" ? ["focused"] : kind == "edits" ? ["count"] : []))
        guard Set(object.keys) == keys else { throw BridgeError.invalidPacket }
        for name in ["version", "sequence"] + (kind == "edits" ? ["count"] : []) {
            guard let value = object[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { throw BridgeError.invalidPacket }
        }
        if kind == "focus" {
            guard let value = object["focused"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw BridgeError.invalidPacket }
        }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        guard packet.version == 1, ["vscode", "vscode-insiders"].contains(packet.editor),
              UUID(uuidString: packet.nonce) != nil, packet.sequence > 0, packet.sequence <= Int32.max,
              packet.kind != .edits || (1...256).contains(packet.count ?? 0) else { throw BridgeError.invalidPacket }
        return packet
    }
}
public enum BridgeError: Error { case invalidPacket, unsafeLocation, socketFailure }
public enum ObservationBridgeEvent: Sendable { case packet(ObservationPacket), disconnected, failed }

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
        case .heartbeat: break
        }
    }
    public mutating func disconnect() { focused = nil; partial = true; nonce = nil; sequence = 0 }
}

/// Disabled until the UI explicitly opts in. Same-user private Unix socket,
/// no TCP/network endpoint, no raw packet log, and no existing-path replacement.
public final class ObservationBridgeServer: @unchecked Sendable {
    private final class Client {
        var fd: Int32
        var source: DispatchSourceRead?
        var timer: DispatchSourceTimer?
        var buffer = Data()
        var windowStart = DispatchTime.now().uptimeNanoseconds
        var packetCount = 0
        init(_ fd: Int32) { self.fd = fd }
    }
    private let queue = DispatchQueue(label: "contextos.observation-bridge", qos: .utility)
    private let callback: @Sendable (ObservationBridgeEvent) -> Void
    private var listener: DispatchSourceRead?
    private var socketFD: Int32 = -1
    private var clients: [Int32: Client] = [:]
    private var ownedPath: String?
    private var ownedInode: ino_t?
    public init(callback: @escaping @Sendable (ObservationBridgeEvent) -> Void) { self.callback = callback }
    public func start(directory: URL) { queue.async { self.open(directory) } }
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
            let path = directory.appendingPathComponent("observations.sock").path
            guard path.utf8.count < 104, lstat(path, &status) != 0, errno == ENOENT else { throw BridgeError.unsafeLocation }
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
            listener = source; source.setEventHandler { [weak self] in self?.acceptClients() }; source.resume()
        } catch { shutdown(); callback(.failed) }
    }
    private func acceptClients() {
        while true {
            let fd = accept(socketFD, nil, nil)
            guard fd >= 0 else { break }
            var uid: uid_t = 0, gid: gid_t = 0
            guard clients.isEmpty, getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); continue }
            let client = Client(fd); clients[fd] = client
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            client.source = source; source.setEventHandler { [weak self] in self?.readClient(fd) }; source.resume()
            resetTimeout(client, seconds: 180)
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
            do { callback(.packet(try ObservationPacket.decode(Data(frame)))) }
            catch { drop(fd); return }
            client.buffer.removeSubrange(...newline)
        }
        guard client.buffer.count <= 1024 else { drop(fd); return }
        resetTimeout(client, seconds: client.buffer.isEmpty ? 180 : 5)
    }
    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source?.cancel(); client.timer?.cancel(); close(fd); callback(.disconnected)
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
    }
}
