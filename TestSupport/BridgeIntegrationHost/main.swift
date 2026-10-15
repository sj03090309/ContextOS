import Foundation
import ContextOSCore
import ContextOSUsage

/// Test-only executable. Never constructs AppKit, reads user settings, or uses
/// the candidate's real container. Time and events are explicitly synthetic.
final class IntegrationHost: @unchecked Sendable {
    private let gate = NSLock()
    private let directory: URL
    private let base = Date(timeIntervalSince1970: 1_792_022_400) // fixed test epoch
    private var seconds: UInt64 = 0
    private var receipts = 0
    private var ledger: EstimatedActivityLedger
    private lazy var server = ObservationBridgeServer { [weak self] event in self?.receive(event) }
    init(path: String) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let canonical = url.resolvingSymlinksInPath().path
        guard canonical.hasPrefix("/private/tmp/cxi-") || canonical.hasPrefix("/tmp/cxi-"),
              url.lastPathComponent == "ContextOS Observation Candidate", url.path.utf8.count + 18 < 104 else {
            throw BridgeError.unsafeLocation
        }
        directory = url
        ledger = EstimatedActivityLedger(now: base, timeZone: .gmt)
    }
    func start() { server.start(directory: directory) }
    private var wall: Date { base.addingTimeInterval(Double(seconds)) }
    private var tick: UInt64 { seconds * 1_000_000_000 }
    private func emit(_ object: [String: Any]) {
        guard var bytes = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        bytes.append(10); try? FileHandle.standardOutput.write(contentsOf: bytes)
    }
    private func snapshotObject() -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? JSONSerialization.jsonObject(with: encoder.encode(ledger.snapshot)) as? [String: Any]) ?? [:]
    }
    private func receive(_ event: ObservationBridgeEvent) {
        gate.lock()
        switch event {
        case .packet(let packet):
            let signal: EstimatedActivitySignal
            switch packet.kind {
            case .focus: signal = .focus(packet.focused == true)
            case .edits, .activity: signal = .activity(focused: packet.focused == true)
            case .heartbeat: signal = .heartbeat
            case .gap: signal = .gap
            }
            ledger.receive(id: packet.nonce, sequence: packet.sequence, signal: signal, tick: tick, wall: wall, timeZone: .gmt)
            receipts += 1
            emit(["type":"packet", "kind":packet.kind.rawValue,"sequence":packet.sequence,"receipts":receipts,"snapshot":snapshotObject()])
        case .disconnected(let id):
            if let id { ledger.disconnect(id: id, tick: tick, wall: wall, timeZone: .gmt) }
            emit(["type":"disconnected","snapshot":snapshotObject()])
        case .failed: emit(["type":"failed"])
        }
        let value = ledger.snapshot; gate.unlock(); server.publish(value)
    }
    func command(_ data: Data) -> Bool {
        guard let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = command["action"] as? String else { return true }
        if action == "quit" { server.stopSynchronously(); return false }
        gate.lock()
        var failure: String?
        if let at = command["at"] as? UInt64 {
            if at >= seconds && at <= 172800 { seconds = at } else { failure = "invalid synthetic clock" }
        }
        if failure == nil {
            switch action {
            case "advance": ledger.advance(tick: tick, wall: wall, timeZone: .gmt)
            case "interrupt": ledger.interrupt(tick: tick, wall: wall, timeZone: .gmt)
            case "save":
                do { try EstimatedActivityStore.write(ledger.snapshot, to: directory.appendingPathComponent("activity-day-v1.json")) }
                catch { failure = "test aggregate save failed" }
            case "restore":
                do {
                    if let saved = try EstimatedActivityStore.read(from: directory.appendingPathComponent("activity-day-v1.json")) {
                        ledger = EstimatedActivityLedger(now: wall, timeZone: .gmt)
                        ledger.restore(saved, now: wall, timeZone: .gmt)
                    } else { failure = "test aggregate missing" }
                } catch { failure = "test aggregate restore failed" }
            case "snapshot": break
            default: failure = "unknown test command"
            }
        }
        var output: [String: Any] = ["type":"reply","request":command["request"] as? String ?? "", "snapshot":snapshotObject(),"receipts":receipts]
        if let failure { output["error"] = failure }
        emit(output); let value = ledger.snapshot; gate.unlock(); server.publish(value)
        return true
    }
    func stop() { server.stopSynchronously() }
}

guard CommandLine.arguments.count == 2 else { fatalError("Explicit /tmp/cxi-* test directory required") }
let host = try IntegrationHost(path: CommandLine.arguments[1]); host.start()
while let line = readLine() { if !host.command(Data(line.utf8)) { break } }
host.stop()
