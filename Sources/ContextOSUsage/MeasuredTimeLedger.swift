import Foundation

/// Distinct observations, never a combined or inferred "coding time".
public enum TimeMeasurement: String, CaseIterable, Codable, Sendable {
    case manualTimer, editorForeground, aiRun
    public var label: String {
        switch self {
        case .manualTimer: "작업 타이머"
        case .editorForeground: "전경 에디터 체류"
        case .aiRun: "AI 실행구간"
        }
    }
}

public struct MeasuredTimeValue: Equatable, Sendable {
    /// nil means no completed observation, not measured zero.
    public var nanoseconds: UInt64?
    public var partial: Bool
}

/// Candidate-only core. Callers supply actual monotonic observation points from
/// one observation epoch. No file/keyboard/window-title access or idle inference.
/// A restart creates a new ledger; open intervals must never be restored.
public struct MeasuredTimeLedger: Sendable {
    private struct Key: Hashable, Sendable { var source: TimeMeasurement; var id: String }
    private struct Span: Sendable { var start: UInt64; var end: UInt64 }
    private var active: [Key: UInt64] = [:]
    private var spans: [TimeMeasurement: [Span]] = [:]
    private var completed = Set<TimeMeasurement>()
    private var partial = Set<TimeMeasurement>()
    public private(set) var editEventCount: UInt64?
    public let maximumActive: Int
    public let maximumRangesPerMeasurement: Int
    public var activeCount: Int { active.count }
    public var rangeCount: Int { spans.values.reduce(0) { $0 + $1.count } }

    public init(maximumActive: Int = 64, maximumRangesPerMeasurement: Int = 512) {
        self.maximumActive = max(1, min(maximumActive, 64))
        self.maximumRangesPerMeasurement = max(1, min(maximumRangesPerMeasurement, 512))
    }

    @discardableResult public mutating func begin(_ source: TimeMeasurement, id: String, at tick: UInt64) -> Bool {
        let key = Key(source: source, id: id)
        guard active[key] == nil else { return false } // Replayed start must not reset the origin.
        guard !id.isEmpty, id.utf8.count <= 128, active.count < maximumActive else {
            partial.insert(source); return false
        }
        active[key] = tick
        return true
    }

    @discardableResult public mutating func end(_ source: TimeMeasurement, id: String, at tick: UInt64) -> Bool {
        guard let start = active.removeValue(forKey: Key(source: source, id: id)) else { return false }
        guard tick >= start else { partial.insert(source); return false }
        completed.insert(source)
        if tick == start { return true } // Explicit zero is valid.
        let ordered = ((spans[source] ?? []) + [Span(start: start, end: tick)]).sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }
        var merged: [Span] = []
        for span in ordered {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else { merged.append(span) }
        }
        guard merged.count <= maximumRangesPerMeasurement else {
            partial.insert(source); return false // Keep verified history; do not invent discarded coverage.
        }
        spans[source] = merged
        return true
    }

    /// On sleep/disconnection/restart/time-zone change: discard unfinished
    /// coverage. No interval extends to an assumed end or resumes by itself.
    public mutating func interrupt() {
        partial.formUnion(active.keys.map(\.source))
        active.removeAll(keepingCapacity: true)
    }

    /// Counts observed content-change callbacks only. It contributes no time,
    /// and does not identify human versus automated/AI authorship.
    public mutating func observeEdit() {
        let (value, overflow) = (editEventCount ?? 0).addingReportingOverflow(1)
        editEventCount = overflow ? .max : value
    }

    public func value(for source: TimeMeasurement) -> MeasuredTimeValue {
        guard completed.contains(source) else { return .init(nanoseconds: nil, partial: partial.contains(source)) }
        var total: UInt64 = 0
        for span in spans[source] ?? [] {
            let (next, overflow) = total.addingReportingOverflow(span.end - span.start)
            if overflow { return .init(nanoseconds: .max, partial: true) }
            total = next
        }
        return .init(nanoseconds: total, partial: partial.contains(source))
    }
}
