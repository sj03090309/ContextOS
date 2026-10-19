import Foundation

/// Provider identity stays separate even when two tools report the same name.
public struct UsageModelKey: Hashable, Sendable {
    private static let unknownNames: Set<String> = ["", "unknown", "unknown model", "unknown-model", "unknown_model", "(unknown)", "모델 미상", "미상"]
    public var provider: String
    public var model: String
    public init(provider: String, model: String) {
        self.provider = provider
        self.model = Self.displayName(model)
    }
    public static func displayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return unknownNames.contains(trimmed.lowercased()) ? "모델 미상" : trimmed
    }
}

/// Today's token events after collector deduplication, not a session's last
/// model multiplied by its whole-day total. No paths or session identity.
public struct TodayModelUsage: Sendable, Equatable, Identifiable {
    public var key: UsageModelKey
    public var tokens: Int64
    public var id: UsageModelKey { key }
    public init(provider: String, model: String, tokens: Int64) {
        key = .init(provider: provider, model: model); self.tokens = max(0, tokens)
    }
    public static func ordered(_ values: [Self]) -> [Self] {
        values.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            if $0.key.provider != $1.key.provider { return $0.key.provider < $1.key.provider }
            return $0.key.model < $1.key.model
        }
    }
}

public struct ModelUsagePreview: Sendable {
    public var visible: [TodayModelUsage]
    public var hiddenCount: Int
    public var hiddenTokens: Int64
    public var totalTokens: Int64
    public init(_ models: [TodayModelUsage], limit: Int = 3, expanded: Bool = false) {
        let ordered = TodayModelUsage.ordered(models)
        let count = expanded ? ordered.count : min(max(0, limit), ordered.count)
        visible = Array(ordered.prefix(count))
        hiddenCount = ordered.count - count
        hiddenTokens = ordered.dropFirst(count).map(\.tokens).reduce(0, UsageNumbers.add)
        totalTokens = ordered.map(\.tokens).reduce(0, UsageNumbers.add)
    }
}

/// Groups only the current model labels of unique observed sessions for status
/// display. Token attribution comes exclusively from TodayModelUsage above.
public struct ModelSessionGroup: Sendable, Identifiable {
    public var key: UsageModelKey
    public var sessions: [ObservedSession]
    public var id: UsageModelKey { key }
    public var working: Int { sessions.filter { $0.state == .working }.count }
    public var waiting: Int { sessions.filter { $0.state == .waiting }.count }
    public static func groups(_ sessions: [ObservedSession], provider: String) -> [Self] {
        var unique: [String: ObservedSession] = [:]
        for session in sessions where session.agent == provider {
            if let old = unique[session.id], (old.lastEvent ?? .distantPast) >= (session.lastEvent ?? .distantPast) { continue }
            unique[session.id] = session
        }
        return Dictionary(grouping: unique.values, by: { UsageModelKey(provider: $0.agent, model: $0.model) })
            .map { key, values in
                Self(key: key, sessions: values.sorted {
                    if $0.lastEvent != $1.lastEvent { return ($0.lastEvent ?? .distantPast) > ($1.lastEvent ?? .distantPast) }
                    return $0.id < $1.id
                })
            }.sorted {
                if $0.working != $1.working { return $0.working > $1.working }
                if $0.waiting != $1.waiting { return $0.waiting > $1.waiting }
                if $0.sessions.count != $1.sessions.count { return $0.sessions.count > $1.sessions.count }
                return $0.key.model < $1.key.model
            }
    }
}
