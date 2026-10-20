import Foundation

public enum SmallWidgetMetric: String, Codable, CaseIterable, Sendable {
    case tokens, activity, workTimer, editorForeground
    public var label: String {
        switch self {
        case .tokens: "오늘 토큰"
        case .activity: "오늘 활동 · 추정"
        case .workTimer: "작업 타이머"
        case .editorForeground: "전경 에디터 체류"
        }
    }
}

public enum TimeObservationState: String, Codable, Sendable {
    case notObserved, running, paused, waitingForEditor, interrupted, partial
    public var label: String {
        switch self {
        case .notObserved: "관측 안 됨"
        case .running: "관측 중"
        case .paused: "일시정지"
        case .waitingForEditor: "지원 에디터 대기"
        case .interrupted: "관측 중단"
        case .partial: "일부 관측"
        }
    }
}

/// Verified aggregate only. No app bundle IDs, titles, source IDs or paths.
/// Values belong to this observation epoch, not an inferred calendar-day total.
public struct WidgetTimeSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var timeZoneID: String
    public var manualNanoseconds: UInt64?
    public var foregroundNanoseconds: UInt64?
    public var manualState: TimeObservationState
    public var foregroundState: TimeObservationState
    public var activity: EstimatedActivitySnapshot?
    public var isSample: Bool
    public init(generatedAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier,
                manualNanoseconds: UInt64? = nil, foregroundNanoseconds: UInt64? = nil,
                manualState: TimeObservationState = .notObserved,
                foregroundState: TimeObservationState = .notObserved, isSample: Bool = false, activity: EstimatedActivitySnapshot? = nil) {
        self.generatedAt = generatedAt; self.timeZoneID = timeZoneID
        self.manualNanoseconds = manualNanoseconds; self.foregroundNanoseconds = foregroundNanoseconds
        self.manualState = manualState; self.foregroundState = foregroundState; self.isSample = isSample; self.activity = activity
    }
    public func stale(at now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) > 30 * 60 || generatedAt > now.addingTimeInterval(300)
            || timeZoneID != TimeZone.current.identifier
    }
    public static func duration(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds else { return "—" }
        let seconds = nanoseconds / 1_000_000_000
        if seconds >= 360_000 { return "≥100h" }
        return String(format: "%02llu:%02llu:%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
