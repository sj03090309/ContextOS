import Foundation

public struct AgentProjectUsage: Sendable, Identifiable {
    public var provider: String
    public var displayName: String
    public var projectPath: String
    public var tokens: Int

    public var id: String { provider + ":" + projectPath }

    public init(provider: String, displayName: String, projectPath: String, tokens: Int) {
        self.provider = provider
        self.displayName = displayName
        self.projectPath = projectPath
        self.tokens = tokens
    }
}

public enum AgentCatUsageReader {
    private struct Snapshot: Decodable {
        var providers: [String: Provider]
    }

    private struct Provider: Decodable {
        var displayName: String?
        var providerLabel: String?
        var projects: Projects?
        var status: String?
    }

    private struct Projects: Decodable {
        var items: [ProjectItem]
    }

    private struct ProjectItem: Decodable {
        var path: String
        var tokens: Int
    }

    public static func projectUsage(maxCacheAge: TimeInterval = 30) async -> [String: [AgentProjectUsage]] {
        await AgentCatUsageCache.shared.projectUsage(maxCacheAge: maxCacheAge)
    }

    fileprivate static func readProjectUsage() -> [String: [AgentProjectUsage]] {
        guard let data = snapshotData(),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return [:] }

        var usageByPath: [String: [AgentProjectUsage]] = [:]
        for (providerKey, provider) in snapshot.providers {
            guard let items = provider.projects?.items, !items.isEmpty else { continue }
            let displayName = provider.displayName ?? provider.providerLabel ?? providerKey.capitalized
            for item in items where item.tokens > 0 && item.path.hasPrefix("/") {
                usageByPath[item.path, default: []].append(AgentProjectUsage(
                    provider: providerKey,
                    displayName: displayName,
                    projectPath: item.path,
                    tokens: item.tokens
                ))
            }
        }

        return usageByPath.mapValues { usages in
            usages.sorted { $0.tokens > $1.tokens }
        }
    }

    private static func snapshotData(timeout: TimeInterval = 5) -> Data? {
        guard let executable = agentCatExecutable() else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["snapshot", "--json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return output.fileHandleForReading.readDataToEndOfFile()
    }

    private static func agentCatExecutable() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/agentcat").path,
            "/opt/homebrew/bin/agentcat",
            "/usr/local/bin/agentcat",
            "/usr/bin/agentcat"
        ]
        return candidates
            .first { fm.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

private actor AgentCatUsageCache {
    static let shared = AgentCatUsageCache()

    private var cachedAt: Date?
    private var cachedUsage: [String: [AgentProjectUsage]] = [:]

    func projectUsage(maxCacheAge: TimeInterval) -> [String: [AgentProjectUsage]] {
        if let cachedAt, Date().timeIntervalSince(cachedAt) < maxCacheAge {
            return cachedUsage
        }
        let usage = AgentCatUsageReader.readProjectUsage()
        cachedAt = Date()
        cachedUsage = usage
        return usage
    }
}
