#if os(macOS) && !CONTEXTOS_PORTABLE_BUILD
import Foundation
import Darwin
import Security
import MachO

/// Waits without polling the filesystem while idle. Each read consumes exactly
/// one line, leaving pipelined requests in the kernel across an executable swap.
final class MCPStdioInput {
    private static let resumeKey = "CONTEXTOS_MCP_RESUMED_SESSION"
    private let executableURL: URL?
    private let contract: [String: Any]
    private let validateCandidate: (URL) -> Bool
    private var loaded: FileIdentity?
    private var rejected: FileIdentity?
    private enum HandshakePhase { case unnegotiated, negotiated, ready }
    private var handshake: HandshakePhase
    let resumedSession: Bool

    private struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var seconds: Int
        var nanoseconds: Int
        var owner: uid_t
        var mode: mode_t
    }

    init(contract: Data, executableURL: URL? = MCPStdioInput.installedExecutable(),
         candidateValidator: ((URL) -> Bool)? = nil) {
        self.contract = (try? JSONSerialization.jsonObject(with: contract)) as? [String: Any] ?? [:]
        self.executableURL = executableURL
        if let executableURL { loaded = Self.runningIdentity() ?? Self.identity(executableURL) }
        else { loaded = nil }
        if let candidateValidator { validateCandidate = candidateValidator }
        else if executableURL != nil { validateCandidate = Self.signedCandidateValidator() }
        else { validateCandidate = { _ in false } }
        resumedSession = getenv(Self.resumeKey).map { String(cString: $0) == "1" } ?? false
        unsetenv(Self.resumeKey)
        handshake = resumedSession ? .ready : .unnegotiated
    }

    func markNegotiated() {
        if handshake == .unnegotiated { handshake = .negotiated }
    }

    func markInitialized() {
        if handshake == .negotiated { handshake = .ready }
    }

    func nextLine() -> String? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&descriptor, 1, -1)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLNVAL) == 0 else { return nil }
            break // POLLHUP may still have unread bytes, including an EOF tail.
        }
        reloadBeforeReading()
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self) }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes.append(byte)
        }
    }

    /// Keep the original launch path. Bundle/dyld paths can point at the retained
    /// previous app after installation moves the directory underneath this process.
    static func installedExecutable() -> URL? {
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        guard url.lastPathComponent == "contextos-mcp",
              url.deletingLastPathComponent().lastPathComponent == "Resources",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents"
        else { return nil }
        let contents = url.deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.contextos.app" else { return nil }
        return url
    }

    private static func identity(_ url: URL) -> FileIdentity? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_mode & 0o022 == 0, access(url.path, X_OK) == 0 else { return nil }
        return FileIdentity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                            seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec,
                            owner: value.st_uid, mode: value.st_mode)
    }

    /// The launch path can already name the next build during process startup.
    /// Read the actual mapped image's vnode, including after rename/unlink,
    /// instead of mistaking that newer path for the code running in this PID.
    private static func runningIdentity() -> FileIdentity? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var region = proc_regionwithpathinfo()
        let address = UInt64(UInt(bitPattern: header))
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return nil }
        let value = region.prp_vip.vip_vi.vi_stat
        guard value.vst_ino != 0 else { return nil }
        return FileIdentity(device: dev_t(bitPattern: value.vst_dev), inode: value.vst_ino,
                            size: value.vst_size, seconds: Int(value.vst_mtime), nanoseconds: Int(value.vst_mtimensec),
                            owner: value.vst_uid, mode: value.vst_mode)
    }

    /// Capture the running image's signing requirement, never the new path's
    /// identity after a swap. Development-signed releases retain their team and
    /// executable identifier. Ad-hoc images stay pinned to their original hash.
    private static func signedCandidateValidator() -> (URL) -> Bool {
        var running: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return { _ in false } }
        return { candidate in
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(candidate as CFURL, [], &code) == errSecSuccess,
                  let code else { return false }
            return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
        }
    }

    private func reloadBeforeReading() {
        // Consume the ready notification with the process that replied to
        // initialize, so a replacement never loses a half-finished handshake.
        guard handshake != .negotiated,
              let executableURL, let original = loaded,
              let candidate = Self.identity(executableURL), candidate != original,
              candidate != rejected else { return }
        rejected = candidate // A failed build must not delay every later request.
        guard candidate.owner == original.owner, validateCandidate(executableURL),
              let next = Self.readContract(executableURL), compatible(next),
              Self.identity(executableURL) == candidate else {
            Self.log("Update deferred: executable trust or MCP contract does not match this connection.")
            return
        }
        let arguments = CommandLine.arguments
        var pointers = arguments.enumerated().map { strdup($0.offset == 0 ? executableURL.path : $0.element) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            pointers.forEach { free($0) }
            return
        }
        pointers.append(nil)
        if handshake == .ready { setenv(Self.resumeKey, "1", 1) }
        Self.log("Loading the updated MCP executable at an idle request boundary.")
        executableURL.path.withCString { path in
            pointers.withUnsafeMutableBufferPointer { arguments in
                _ = execv(path, arguments.baseAddress!)
            }
        }
        // execv returns only on failure; input is still untouched and the old
        // implementation can answer the pending request on the same transport.
        unsetenv(Self.resumeKey)
        pointers.forEach { free($0) }
        Self.log("Executable replacement failed; keeping this MCP connection alive.")
    }

    private func compatible(_ candidate: [String: Any]) -> Bool {
        guard let schema = contract["schema_version"] as? Int,
              candidate["schema_version"] as? Int == schema,
              let version = contract["mcp_protocol_version"] as? String,
              candidate["mcp_protocol_version"] as? String == version,
              let current = contract["mcp_tools"] as? [[String: Any]],
              let next = candidate["mcp_tools"] as? [[String: Any]] else { return false }
        // Descriptions, instructions and additional tools can refresh through
        // list_changed. Keep existing input contracts intact for queued calls.
        return current.allSatisfy { tool in
            guard let name = tool["name"] as? String,
                  let match = next.first(where: { $0["name"] as? String == name }),
                  let before = tool["inputSchema"] as? NSDictionary,
                  let after = match["inputSchema"] as? NSDictionary else { return false }
            return before == after
        }
    }

    private static func readContract(_ executable: URL) -> [String: Any]? {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--contract"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // A client can close its server while a broken candidate is probing.
        // Keep normal termination scoped to this short probe and reap its child.
        var signalSources: [DispatchSourceSignal] = []
        var previousHandlers: [(Int32, sig_t?)] = []
        for number in [SIGTERM, SIGINT] {
            previousHandlers.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler {
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                _exit(128 + number)
            }
            source.resume()
            signalSources.append(source)
        }
        defer {
            signalSources.forEach { $0.cancel() }
            for (number, handler) in previousHandlers { signal(number, handler) }
        }
        do { try process.run() } catch { return nil }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 3)
        watchdog.setEventHandler {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        var finished = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime < deadline {
            var input = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let available = poll(&input, 1, remaining)
            if available < 0 && errno == EINTR { continue }
            guard available > 0 else { break }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count == 0 { finished = true; break }
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 256 * 1024 { break }
        }
        if !finished && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard finished, data.count <= 256 * 1024, process.terminationStatus == 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[contextos-mcp] " + message + "\n").utf8))
    }
}
#endif
