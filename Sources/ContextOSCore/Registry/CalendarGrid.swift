import Foundation

/// Lays a month out into calendar rows, and labels days.
///
/// Pure date math with no view code, so it can be tested — the app target is an
/// executable and gets no test coverage of its own.
public enum CalendarGrid {

    public struct Day: Sendable, Equatable {
        public var key: String        // yyyy-MM-dd
        public var number: Int
        public var isToday: Bool
    }

    /// Rows of 7, Sunday-first, with nil padding outside the month.
    public static func weeks(of month: Date) -> [[Day?]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: month)
        guard let year = parts.year, let monthNumber = parts.month,
              let first = calendar.date(from: DateComponents(year: year, month: monthNumber, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first)
        else { return [] }

        let today = TimeKeys.localDay(Date().timeIntervalSince1970)
        let leading = calendar.component(.weekday, from: first) - 1     // 0 = Sunday
        var cells: [Day?] = Array(repeating: nil, count: leading)
        for day in range {
            let key = TimeKeys.dayKey(year: year, month: monthNumber, day: day)
            cells.append(Day(key: key, number: day, isToday: key == today))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// "2026년 7월"
    public static func title(_ month: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month], from: month)
        return "\(parts.year ?? 0)년 \(parts.month ?? 0)월"
    }

    /// Sum of a month's daily values.
    public static func total(_ month: Date, _ byDay: [String: Int]) -> Int {
        let keys = Set(weeks(of: month).flatMap { $0 }.compactMap { $0?.key })
        return byDay.filter { keys.contains($0.key) }.values.reduce(0, +)
    }

    // MARK: - Day labels

    private static let weekdayNames = ["일", "월", "화", "수", "목", "금", "토"]

    /// 0 = Sunday … 6 = Saturday, for a `yyyy-MM-dd` key.
    public static func weekdayIndex(of day: String) -> Int? {
        guard let (y, m, d) = parse(day) else { return nil }
        // The Unix epoch (1970-01-01) was a Thursday, index 4. The extra +7
        // keeps the result non-negative for pre-epoch dates.
        return ((TimeKeys.daysFromCivil(year: y, month: m, day: d) % 7) + 7 + 4) % 7
    }

    /// "수요일"
    public static func weekdayLabel(_ day: String) -> String {
        guard let index = weekdayIndex(of: day) else { return "" }
        return weekdayNames[index] + "요일"
    }

    /// "7월 15일" — or "오늘"/"어제", the two days people actually ask about.
    public static func heading(_ day: String, now: Double = Date().timeIntervalSince1970) -> String {
        if day == TimeKeys.localDay(now) { return "오늘" }
        if day == TimeKeys.localDay(now - 86_400) { return "어제" }
        guard let (_, month, date) = parse(day) else { return day }
        return "\(month)월 \(date)일"
    }

    private static func parse(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        return (y, m, d)
    }
}
