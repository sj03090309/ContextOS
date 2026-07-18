import Foundation

/// How far back the build log looks.
///
/// Lives in Core rather than the view so the range arithmetic — which decides
/// what the user sees — is testable; the app target is an executable and gets no
/// test coverage of its own.
public enum BuildPeriod: String, CaseIterable, Sendable {
    case week
    case month
    case quarter

    /// Days included, counting today. Ordered narrowest → widest, which
    /// `covering(day:)` relies on.
    public var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    public var label: String {
        switch self {
        case .week: return "이번 주"
        case .month: return "이번 달"
        case .quarter: return "90일"
        }
    }

    /// Epoch seconds this period starts at, snapped to local midnight so a day
    /// is either wholly in or wholly out.
    public func since(now: Double = Date().timeIntervalSince1970) -> Double {
        TimeKeys.localStartOfDay(now - Double(days - 1) * 86_400)
    }

    /// The narrowest period that reaches back far enough to include `day`, or
    /// nil if the day is older than any period offered.
    ///
    /// Used when a day is picked on the calendar: the calendar always shows a
    /// whole month while the timeline shows the selected period, so a tapped day
    /// is routinely outside the loaded range. Widening beats showing nothing.
    public static func covering(day: String, now: Double = Date().timeIntervalSince1970) -> BuildPeriod? {
        let start = BuildLogReader.dayStart(day)
        return allCases.first { start >= $0.since(now: now) }
    }
}
