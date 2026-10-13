import Foundation

/// UTC persisted lifecycle-event domain, separate from monotonic live timers.
public struct ExplicitAIRunEvent: Hashable, Sendable {
    public enum Kind: String, Sendable { case start, end, abort }
    public var id: String
    public var kind: Kind
    public var date: Date
    public init(id: String, kind: Kind, date: Date) { self.id = id; self.kind = kind; self.date = date }
}

public struct AIExecutionSummary: Equatable, Sendable {
    public var todayMilliseconds: UInt64?
    public var state: CollectionState
    public var missingPairs: Int
    public var generatedAt: Date
    public var timeZoneID: String
    public init(todayMilliseconds: UInt64? = nil, state: CollectionState = .noRecords, missingPairs: Int = 0,
                generatedAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier) {
        self.todayMilliseconds = todayMilliseconds; self.state = state; self.missingPairs = missingPairs
        self.generatedAt = generatedAt; self.timeZoneID = timeZoneID
    }
    public var formatted: String {
        guard let ms = todayMilliseconds else { return "—" }
        let (ns, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
        return WidgetTimeSnapshot.duration(overflow ? .max : ns) // Actual daily union is at most 25 hours.
    }
}

public enum ExplicitAIRuns {
    /// Exactly one distinct start and end for an ID. Copied/replayed identical
    /// events deduplicate. Conflicts, orphan ends, aborts and open ranges add no time.
    public static func summarize(_ events: [ExplicitAIRunEvent], now: Date, timeZone: TimeZone,
                                 incomplete: Bool = false, available: Bool = true) -> AIExecutionSummary {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: now), endDay = calendar.date(byAdding: .day, value: 1, to: day)!
        var missing = 0, completedToday = false, ranges: [(Date, Date)] = []
        let bounded = events.prefix(20_000)
        for group in Dictionary(grouping: Set(bounded), by: \.id).values {
            let starts = group.filter { $0.kind == .start }, ends = group.filter { $0.kind == .end }
            guard starts.count == 1, ends.count == 1, !group.contains(where: { $0.kind == .abort }),
                  let s = starts.first?.date, let e = ends.first?.date,
                  s.timeIntervalSince1970.isFinite, e.timeIntervalSince1970.isFinite,
                  s <= e, e <= now else { missing += 1; continue }
            guard e >= day && s < endDay else { continue }
            completedToday = true
            ranges.append((max(s, day), min(e, endDay)))
        }
        ranges.sort { $0.0 < $1.0 }
        var union: [(Date, Date)] = []
        for range in ranges {
            if let last = union.last, range.0 <= last.1 { union[union.count - 1].1 = max(last.1, range.1) }
            else { union.append(range) }
        }
        let milliseconds = union.reduce(0.0) { $0 + max(0, $1.1.timeIntervalSince($1.0)) * 1000 }
        let partial = incomplete || events.count > 20_000 || missing > 0
        return .init(todayMilliseconds: completedToday ? UInt64(milliseconds.rounded(.down)) : nil,
                     state: !available ? .unavailable : partial ? .partial : completedToday ? .ready : .noRecords,
                     missingPairs: missing, generatedAt: now, timeZoneID: timeZone.identifier)
    }
}
