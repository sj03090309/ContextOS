import Foundation
import Testing
@testable import ContextOSCore

@Suite("CalendarGrid")
struct CalendarGridTests {

    private func date(_ iso: String) -> Date {
        Date(timeIntervalSince1970: TimeKeys.epoch(fromISO8601: iso + "T12:00:00Z") ?? 0)
    }

    @Test("weekday labels agree with Foundation over a full year")
    func weekdaysMatchFoundation() {
        // The label comes from arithmetic on the epoch, not from Calendar, so it
        // is worth checking against the real thing rather than a few spot values.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for offset in 0..<400 {
            let day = Date(timeIntervalSince1970: 1_782_000_000 + Double(offset) * 86_400)
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let key = TimeKeys.dayKey(year: parts.year!, month: parts.month!, day: parts.day!)
            // Foundation's weekday is 1-based from Sunday; ours is 0-based.
            #expect(CalendarGrid.weekdayIndex(of: key) == parts.weekday! - 1,
                    "weekday mismatch on \(key)")
        }
    }

    @Test("known weekdays render in Korean")
    func weekdayLabels() {
        #expect(CalendarGrid.weekdayLabel("2026-07-15") == "수요일")
        #expect(CalendarGrid.weekdayLabel("2026-07-14") == "화요일")
        #expect(CalendarGrid.weekdayLabel("2024-02-29") == "목요일")   // leap day
        #expect(CalendarGrid.weekdayLabel("2026-01-01") == "목요일")
        #expect(CalendarGrid.weekdayLabel("garbage") == "")
    }

    @Test("headings name today and yesterday instead of a date")
    func headings() {
        let now = Date().timeIntervalSince1970
        #expect(CalendarGrid.heading(TimeKeys.localDay(now), now: now) == "오늘")
        #expect(CalendarGrid.heading(TimeKeys.localDay(now - 86_400), now: now) == "어제")
        #expect(CalendarGrid.heading("2026-07-03", now: now) == "7월 3일")
        #expect(CalendarGrid.heading("nonsense", now: now) == "nonsense")
    }

    @Test("a month lays out as whole Sunday-first weeks")
    func monthLayout() throws {
        // July 2026: 31 days, the 1st is a Wednesday.
        let weeks = CalendarGrid.weeks(of: date("2026-07-15"))
        #expect(weeks.allSatisfy { $0.count == 7 })

        let days = weeks.flatMap { $0 }.compactMap { $0 }
        #expect(days.count == 31)
        #expect(days.first?.key == "2026-07-01")
        #expect(days.last?.key == "2026-07-31")

        // The 1st sits under Wednesday, so the first row has three empty cells.
        #expect(weeks[0][0] == nil)
        #expect(weeks[0][1] == nil)
        #expect(weeks[0][2] == nil)
        #expect(weeks[0][3]?.number == 1)

        // Every day lands in the column its weekday says it should.
        for (row, week) in weeks.enumerated() {
            for (column, day) in week.enumerated() {
                guard let day else { continue }
                #expect(CalendarGrid.weekdayIndex(of: day.key) == column,
                        "\(day.key) in row \(row) column \(column)")
            }
        }
    }

    @Test("February handles leap years")
    func februaryLeapYear() {
        #expect(CalendarGrid.weeks(of: date("2024-02-10")).flatMap { $0 }.compactMap { $0 }.count == 29)
        #expect(CalendarGrid.weeks(of: date("2026-02-10")).flatMap { $0 }.compactMap { $0 }.count == 28)
    }

    @Test("month totals count only that month's days")
    func monthTotal() {
        let byDay = [
            "2026-06-30": 5,      // previous month
            "2026-07-01": 10,
            "2026-07-31": 20,
            "2026-08-01": 40      // next month
        ]
        #expect(CalendarGrid.total(date("2026-07-15"), byDay) == 30)
    }

    @Test("titles read as a Korean year and month")
    func titles() {
        #expect(CalendarGrid.title(date("2026-07-15")) == "2026년 7월")
        #expect(CalendarGrid.title(date("2026-12-01")) == "2026년 12월")
    }
}
