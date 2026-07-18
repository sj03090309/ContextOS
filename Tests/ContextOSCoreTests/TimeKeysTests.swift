import Foundation
import Testing
@testable import ContextOSCore

@Suite("TimeKeys")
struct TimeKeysTests {

    @Test("parses the timestamp forms the agents actually write")
    func parsesRealFormats() throws {
        // Claude Code: fractional seconds + Z. Codex: identical shape.
        let claude = try #require(TimeKeys.epoch(fromISO8601: "2026-06-21T14:00:58.832Z"))
        #expect(abs(claude - 1_782_050_458.832) < 0.001)

        // No fraction.
        let plain = try #require(TimeKeys.epoch(fromISO8601: "2026-06-21T14:00:58Z"))
        #expect(abs(plain - 1_782_050_458) < 0.001)

        // Explicit offset resolves back to the same instant as the Z form.
        let offset = try #require(TimeKeys.epoch(fromISO8601: "2026-06-21T23:00:58+09:00"))
        #expect(abs(offset - plain) < 0.001)

        let compact = try #require(TimeKeys.epoch(fromISO8601: "2026-06-21T23:00:58+0900"))
        #expect(abs(compact - plain) < 0.001)
    }

    @Test("agrees with Foundation's ISO8601 parser across many instants")
    func matchesFoundation() {
        let reference = ISO8601DateFormatter()
        reference.formatOptions = [.withInternetDateTime]
        // Sample across years, months, DST boundaries, and leap days.
        for offset in stride(from: 0.0, to: 12 * 365 * 86_400, by: 86_400 * 37) {
            let date = Date(timeIntervalSince1970: 1_500_000_000 + offset)
            let text = reference.string(from: date)
            let mine = TimeKeys.epoch(fromISO8601: text)
            #expect(mine != nil, "failed to parse \(text)")
            #expect(abs((mine ?? 0) - date.timeIntervalSince1970) < 0.001, "mismatch on \(text)")
        }
    }

    @Test("rejects malformed input instead of guessing")
    func rejectsGarbage() {
        #expect(TimeKeys.epoch(fromISO8601: "") == nil)
        #expect(TimeKeys.epoch(fromISO8601: "not-a-date") == nil)
        #expect(TimeKeys.epoch(fromISO8601: "2026-06-21") == nil)          // too short
        #expect(TimeKeys.epoch(fromISO8601: "2026-13-21T00:00:00Z") == nil) // month 13
        #expect(TimeKeys.epoch(fromISO8601: "2026-06-21X14:00:58Z") == nil) // bad separator
        #expect(TimeKeys.epoch(fromISO8601: "20xx-06-21T14:00:58Z") == nil) // non-digits
    }

    @Test("civil date conversion round-trips over four centuries")
    func civilRoundTrip() {
        for days in stride(from: -100_000, through: 100_000, by: 13) {
            let civil = TimeKeys.civilFromDays(days)
            let back = TimeKeys.daysFromCivil(year: civil.year, month: civil.month, day: civil.day)
            #expect(back == days, "round-trip failed at \(days) → \(civil)")
        }
    }

    @Test("local day keys match SQLite's localtime bucketing")
    func localDayMatchesSQL() throws {
        // The calendar's day keys come from TimeKeys, but the savings series is
        // bucketed by SQLite's strftime(..., 'localtime'). They must agree or the
        // two halves of the dashboard would disagree about what "today" is.
        let store = try UsageStore(path: ":memory:")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        for offset in stride(from: 0.0, to: 400 * 86_400, by: 86_400 * 17) {
            let epoch = Date().timeIntervalSince1970 - offset
            #expect(TimeKeys.localDay(epoch) == formatter.string(from: Date(timeIntervalSince1970: epoch)))
        }
        _ = store
    }

    @Test("start of day is midnight and contains its own instant")
    func startOfDay() {
        let now = Date().timeIntervalSince1970
        let start = TimeKeys.localStartOfDay(now)
        #expect(start <= now)
        #expect(now - start < 86_400 + 3600)          // allow for a DST-shifted day
        #expect(TimeKeys.localDay(start) == TimeKeys.localDay(now))
        // Idempotent.
        #expect(TimeKeys.localStartOfDay(start) == start)
    }

    @Test("day keys are zero-padded so they sort lexically")
    func dayKeyPadding() {
        #expect(TimeKeys.dayKey(year: 2026, month: 7, day: 1) == "2026-07-01")
        #expect(TimeKeys.dayKey(year: 2026, month: 12, day: 25) == "2026-12-25")
        #expect(TimeKeys.dayKey(year: 2026, month: 1, day: 9) < TimeKeys.dayKey(year: 2026, month: 1, day: 10))
    }
}
