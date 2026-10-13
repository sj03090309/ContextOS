import Foundation

public enum CollectionState: String, Codable, Sendable {
    case ready, noRecords, unavailable, partial, unsupported
    public var label: String {
        switch self {
        case .ready: "수집됨"
        case .noRecords: "기록 없음"
        case .unavailable: "연결 끊김 · 수집 불가"
        case .partial: "일부 기록만 수집"
        case .unsupported: "지원 예정 · 수집 불가"
        }
    }
}

public enum WorkState: String, Codable, Sendable {
    case working, waiting, idle, interrupted, unknown
    public var label: String {
        switch self {
        case .working: "작업 중"
        case .waiting: "응답 대기"
        case .idle: "유휴 · 턴 종료"
        case .interrupted: "작업 중단"
        case .unknown: "상태 확인 불가"
        }
    }
}

public struct UsageRank: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var tokens: Int64
    public var id: String { name }
    public init(_ name: String, _ tokens: Int64) { self.name = name; self.tokens = tokens }
}

public struct UsageDay: Codable, Sendable, Equatable, Identifiable {
    public var date: Date
    /// nil means no accounting event for this day, never a fabricated zero.
    public var tokens: Int64?
    public var id: Date { date }
    public init(date: Date, tokens: Int64?) { self.date = date; self.tokens = tokens }
}

public struct UsageProvider: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: CollectionState
    public var latestEvent: Date?
    public var id: String { name }
    public init(name: String, state: CollectionState, latestEvent: Date? = nil) {
        self.name = name; self.state = state; self.latestEvent = latestEvent
    }
}

/// The complete shared-container contract. No session IDs, paths, prompts,
/// message bodies, tool arguments, credentials, or provider configuration.
public struct WidgetUsageSnapshot: Codable, Sendable, Equatable {
    public var version = 1
    public var generatedAt: Date
    public var timeZoneID: String
    public var days: [UsageDay]
    public var models: [UsageRank]
    public var agents: [UsageRank]
    public var projects: [UsageRank]
    public var providers: [UsageProvider]
    public var dailyBudget: Int64?
    public var isSample: Bool
    public var timing: WidgetTimeSnapshot?
    public var smallMetric: SmallWidgetMetric?

    public init(generatedAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier,
                days: [UsageDay] = [], models: [UsageRank] = [], agents: [UsageRank] = [],
                projects: [UsageRank] = [], providers: [UsageProvider] = [], dailyBudget: Int64? = nil,
                isSample: Bool = false) {
        self.generatedAt = generatedAt; self.timeZoneID = timeZoneID; self.days = days
        self.models = models; self.agents = agents; self.projects = projects; self.providers = providers
        self.dailyBudget = dailyBudget.flatMap { $0 > 0 ? $0 : nil }; self.isSample = isSample
    }
    public var today: Int64? { days.last?.tokens }
    public var yesterday: Int64? { days.dropLast().last?.tokens }
    public var weekTotal: Int64? {
        let values = days.compactMap(\.tokens)
        return values.isEmpty ? nil : values.reduce(0, UsageNumbers.add)
    }
    public var comparison: String {
        guard let today, let yesterday else { return "전일 비교 기록 없음" }
        guard yesterday > 0 else { return today == 0 ? "전일과 동일" : "전일 0 · 오늘 기록 있음" }
        let pct = (Double(today) / Double(yesterday) - 1) * 100
        if pct > 999 { return "전일 전체 대비 +999% 초과" }
        return String(format: "전일 전체 대비 %+.0f%%", pct)
    }
    public func stale(at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
        return date.timeIntervalSince(generatedAt) > 30 * 60
            || generatedAt > date.addingTimeInterval(300)
            || !calendar.isDate(generatedAt, inSameDayAs: date)
            || timeZoneID != TimeZone.current.identifier
    }
    public var nearBudget: Bool {
        guard let dailyBudget, let today else { return false }
        return Double(today) >= Double(dailyBudget) * 0.8
    }
    public var health: String {
        if isSample { return "미리보기 · 예시 데이터" }
        let supported = providers.filter { $0.state != .unsupported }
        if supported.isEmpty { return "앱 연결 필요" }
        if supported.contains(where: { $0.state == .unavailable || $0.state == .partial }) { return "일부 수집 불가" }
        return supported.contains(where: { $0.state == .ready }) ? "로컬 기록 집계" : "기록 없음"
    }
}

public struct ObservedSession: Sendable, Equatable, Identifiable {
    public var id: String
    public var agent: String
    public var project: String
    public var model: String
    public var state: WorkState
    public var lastEvent: Date?
    public var todayTokens: Int64?
    public var totalTokens: Int64?
    public init(id: String, agent: String, project: String, model: String, state: WorkState,
                lastEvent: Date?, todayTokens: Int64?, totalTokens: Int64?) {
        self.id = id; self.agent = agent; self.project = project; self.model = model
        self.state = state; self.lastEvent = lastEvent; self.todayTokens = todayTokens; self.totalTokens = totalTokens
    }
}

public struct ConcurrentUsageSnapshot: Sendable, Equatable {
    public var widget: WidgetUsageSnapshot
    public var sessions: [ObservedSession]
    public var aiExecution: AIExecutionSummary
    public init(widget: WidgetUsageSnapshot = .init(), sessions: [ObservedSession] = [], aiExecution: AIExecutionSummary = .init()) {
        self.widget = widget; self.sessions = sessions; self.aiExecution = aiExecution
    }
}

public enum UsageNumbers {
    /// Saturating arithmetic prevents malformed counters from crashing the app.
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = max(0, a).addingReportingOverflow(max(0, b))
        return overflow ? Int64.max : value
    }
    public static func compact(_ value: Int64?) -> String {
        guard let value else { return "—" }
        let n = Double(value)
        if n >= 1_000_000_000_000_000 { return String(format: "%.1e", n).replacingOccurrences(of: "e+", with: "e") }
        if n >= 1_000_000_000_000 { return String(format: "%.1fT", n / 1_000_000_000_000) }
        if n >= 1_000_000_000 { return String(format: "%.1fB", n / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", n / 1_000) }
        return String(value)
    }
}
