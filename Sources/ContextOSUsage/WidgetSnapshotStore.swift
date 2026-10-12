import Foundation

public enum WidgetSnapshotStore {
    public static let fileName = "usage-v1.json"
    public static let kind = "ContextOSUsage"
    public static let maximumBytes = 256 * 1024
    /// Only call when a reviewed build explicitly configures a group identifier.
    /// No fallback to an unsandboxed home path or guessed group container.
    public static func container(bundle: Bundle = .main) -> URL? {
        guard let group = bundle.object(forInfoDictionaryKey: "ContextOSAppGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    public static func write(_ snapshot: WidgetUsageSnapshot, to container: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: container.appendingPathComponent(fileName), options: .atomic)
    }
    public static func read(from container: URL) -> WidgetUsageSnapshot? {
        let url = container.appendingPathComponent(fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(WidgetUsageSnapshot.self, from: data),
              snapshot.version == 1, snapshot.days.count <= 7,
              snapshot.days.allSatisfy({ $0.tokens == nil || $0.tokens! >= 0 }),
              snapshot.models.count <= 3, snapshot.agents.count <= 3, snapshot.projects.count <= 3
        else { return nil }
        return snapshot
    }
    public static func detailURL(bundle: Bundle = .main) -> URL {
        let scheme = bundle.object(forInfoDictionaryKey: "ContextOSURLScheme") as? String ?? "contextos"
        return URL(string: "\(scheme)://usage")!
    }
    public static func accepts(_ url: URL, scheme: String) -> Bool {
        url.scheme == scheme && url.host == "usage" && url.path.isEmpty && url.query == nil && url.fragment == nil
    }
}
