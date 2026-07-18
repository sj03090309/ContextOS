import Foundation

/// Date helpers for bucketing agent session logs by day.
///
/// Session transcripts hold tens of thousands of ISO8601 timestamps, and both
/// `DateFormatter` and `ISO8601DateFormatter` are far too slow to run per line.
/// These are hand-rolled conversions over the fixed formats the agents emit,
/// using Howard Hinnant's civil-date algorithms (exact, no lookup tables).
public enum TimeKeys {

    // MARK: - ISO8601 → epoch

    /// Parse the timestamp forms the agents actually write —
    /// `2026-06-21T14:00:58.832Z`, `2026-06-21T14:00:58Z`, and
    /// `2026-06-21T14:00:58.832+09:00` — into epoch seconds.
    /// Returns nil for anything else rather than guessing.
    public static func epoch(fromISO8601 s: String) -> Double? {
        let u = Array(s.utf8)
        // Shortest accepted form is "yyyy-mm-ddThh:mm:ss" (19 chars).
        guard u.count >= 19 else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for i in start..<(start + count) {
                let c = u[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        // Fixed-width positions; bail if the separators aren't where we expect.
        guard u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
              u[10] == UInt8(ascii: "T") || u[10] == UInt8(ascii: " "),
              u[13] == UInt8(ascii: ":"), u[16] == UInt8(ascii: ":"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        var t = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Double(hour * 3600 + minute * 60 + second)

        // Optional fractional seconds, then an optional zone suffix.
        var i = 19
        if i < u.count, u[i] == UInt8(ascii: ".") {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                t += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        guard i < u.count else { return t }              // no zone → treat as UTC
        if u[i] == UInt8(ascii: "Z") || u[i] == UInt8(ascii: "z") { return t }
        // ±hh:mm / ±hhmm offset — subtract it to get back to UTC.
        let sign: Double
        switch u[i] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return t
        }
        guard let oh = digits(i + 1, 2) else { return t }
        let minuteStart = (i + 3 < u.count && u[i + 3] == UInt8(ascii: ":")) ? i + 4 : i + 3
        let om = (minuteStart + 1 < u.count ? digits(minuteStart, 2) : nil) ?? 0
        return t - sign * Double(oh * 3600 + om * 60)
    }

    // MARK: - epoch → local day key

    /// `yyyy-MM-dd` for an instant, in the machine's current timezone —
    /// the same bucket the SQL `'localtime'` day keys use.
    public static func localDay(_ epoch: Double) -> String {
        let shifted = epoch + Double(localOffset(epoch))
        let days = Int(floor(shifted / 86_400))
        let (y, m, d) = civilFromDays(days)
        return dayKey(year: y, month: m, day: d)
    }

    /// Local midnight (as epoch seconds) that starts the day containing `epoch`.
    public static func localStartOfDay(_ epoch: Double) -> Double {
        let offset = Double(localOffset(epoch))
        let days = floor((epoch + offset) / 86_400)
        return days * 86_400 - offset
    }

    /// `yyyy-MM-dd` from components, zero-padded without a formatter.
    public static func dayKey(year: Int, month: Int, day: Int) -> String {
        func pad2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        return "\(year)-\(pad2(month))-\(pad2(day))"
    }

    /// UTC offset in seconds, honoring DST at that instant.
    ///
    /// `TimeZone.secondsFromGMT(for:)` is comparatively expensive and this runs
    /// per log line, so results are memoized per UTC day — an offset only ever
    /// changes at a DST boundary, and being off by a few hours on the two
    /// transition days would at worst move a handful of late-night events into
    /// the neighboring bucket.
    private static func localOffset(_ epoch: Double) -> Int {
        let dayIndex = Int(floor(epoch / 86_400))
        offsetLock.lock()
        defer { offsetLock.unlock() }
        if let hit = offsetCache[dayIndex] { return hit }
        let seconds = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: epoch))
        offsetCache[dayIndex] = seconds
        return seconds
    }

    nonisolated(unsafe) private static var offsetCache: [Int: Int] = [:]
    private static let offsetLock = NSLock()

    /// Drop the memoized UTC offsets — call if the machine's timezone changes.
    public static func resetOffsetCache() {
        offsetLock.lock()
        offsetCache.removeAll()
        offsetLock.unlock()
    }

    // MARK: - Civil date algorithms (Howard Hinnant, public domain)

    /// Days since the Unix epoch for a proleptic-Gregorian y/m/d.
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        var y = year
        y -= month <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400                                     // [0, 399]
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy             // [0, 146096]
        return era * 146_097 + doe - 719_468
    }

    /// Inverse of `daysFromCivil`.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        var z = days
        z += 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097                                 // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)           // [0, 365]
        let mp = (5 * doy + 2) / 153                                // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                        // [1, 31]
        let m = mp + (mp < 10 ? 3 : -9)                             // [1, 12]
        return (y + (m <= 2 ? 1 : 0), m, d)
    }
}
