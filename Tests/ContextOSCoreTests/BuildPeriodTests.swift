import Foundation
import Testing
@testable import ContextOSCore

@Suite("BuildPeriod")
struct BuildPeriodTests {

    private let now = Date().timeIntervalSince1970

    @Test("periods start at local midnight, not at a rolling clock time")
    func startsAtMidnight() {
        // A rolling "now - 7 days" would cut a day in half, so the oldest day in
        // the log would show only part of its work.
        for period in BuildPeriod.allCases {
            let since = period.since(now: now)
            #expect(TimeKeys.localStartOfDay(since) == since, "\(period) is not on a midnight")
        }
    }

    @Test("a period covers exactly its own span of days, today included")
    func spansTheRightDays() {
        for period in BuildPeriod.allCases {
            let since = period.since(now: now)
            // The oldest included day.
            let oldest = TimeKeys.localDay(now - Double(period.days - 1) * 86_400)
            #expect(BuildLogReader.dayStart(oldest) >= since, "\(period) excludes its own oldest day")
            // The day before that must fall outside.
            let tooOld = TimeKeys.localDay(now - Double(period.days) * 86_400)
            #expect(BuildLogReader.dayStart(tooOld) < since, "\(period) reaches a day too far")
            // Today is always in.
            #expect(BuildLogReader.dayStart(TimeKeys.localDay(now)) >= since)
        }
    }

    @Test("periods are ordered narrowest to widest")
    func orderedNarrowToWide() {
        let spans = BuildPeriod.allCases.map(\.days)
        #expect(spans == spans.sorted())
        // `covering` returns the first match, so the order is load-bearing.
        #expect(BuildPeriod.allCases.first == .week)
    }

    @Test("picking a day widens to the narrowest period that reaches it")
    func coveringPicksNarrowest() {
        // This is what happens when a day is tapped on the calendar: the month
        // shown is wider than the timeline's period, so a tap routinely lands
        // outside the loaded range.
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now), now: now) == .week)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 3 * 86_400), now: now) == .week)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 20 * 86_400), now: now) == .month)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 60 * 86_400), now: now) == .quarter)
    }

    @Test("a day at a period boundary picks that period, not the next one up")
    func coveringIsInclusiveAtTheEdge() {
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 6 * 86_400), now: now) == .week)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 7 * 86_400), now: now) == .month)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 29 * 86_400), now: now) == .month)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 30 * 86_400), now: now) == .quarter)
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 89 * 86_400), now: now) == .quarter)
    }

    @Test("a day older than every period reports that nothing covers it")
    func coveringGivesUpHonestly() {
        // The window keeps the day selected and says it has no records, rather
        // than pretending to filter and rendering a blank pane.
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now - 200 * 86_400), now: now) == nil)
        #expect(BuildPeriod.covering(day: "1999-01-01", now: now) == nil)
    }

    @Test("a future day is covered by the narrowest period")
    func futureDay() {
        // Clock skew on a commit timestamp shouldn't strand a day.
        #expect(BuildPeriod.covering(day: TimeKeys.localDay(now + 86_400), now: now) == .week)
    }

    @Test("labels are stable and distinct")
    func labels() {
        let labels = BuildPeriod.allCases.map(\.label)
        #expect(labels == ["이번 주", "이번 달", "90일"])
        #expect(Set(labels).count == labels.count)
    }
}
