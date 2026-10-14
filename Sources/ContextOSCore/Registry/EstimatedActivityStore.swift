import Foundation
import Darwin
import ContextOSUsage

/// One aggregate day, <=16 KiB, private candidate directory. No raw events or
/// identifiers and no active interval persistence. Called only after opt-in.
public enum EstimatedActivityStore {
    public static func read(from file: URL) throws -> EstimatedActivitySnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var st = stat()
        guard lstat(file.path, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG, st.st_size <= 16384 else { throw BridgeError.unsafeLocation }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version","day","timeZoneID","estimatedNanoseconds","phase","partial","idleSeconds","generatedAt"]) else { throw BridgeError.invalidPacket }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(EstimatedActivitySnapshot.self, from: data)
        guard value.version == 1, value.idleSeconds == 300, value.day.utf8.count == 10,
              value.timeZoneID.utf8.count <= 128, TimeZone(identifier: value.timeZoneID) != nil,
              value.estimatedNanoseconds.map({ $0 <= 93_600_000_000_000 }) ?? true else { throw BridgeError.invalidPacket }
        return value
    }
    public static func write(_ value: EstimatedActivitySnapshot, to file: URL) throws {
        var st = stat()
        guard lstat(file.deletingLastPathComponent().path, &st) == 0, st.st_uid == getuid(),
              st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o077 == 0 else { throw BridgeError.unsafeLocation }
        if FileManager.default.fileExists(atPath: file.path) { _ = try read(from: file) }
        else if lstat(file.path, &st) == 0 { throw BridgeError.unsafeLocation } // dangling symlink
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value); guard data.count <= 16384 else { throw BridgeError.invalidPacket }
        try data.write(to: file, options: .atomic)
        guard chmod(file.path, 0o600) == 0 else { throw BridgeError.unsafeLocation }
    }
}
