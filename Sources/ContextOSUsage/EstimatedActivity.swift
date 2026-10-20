import Foundation

/// Product assumption, not measured coding/thinking time. Only the host advances
/// this value; editor status bars and widgets must never extrapolate it locally.
public struct EstimatedActivitySnapshot: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case active, paused, notObserved }
    public var version = 1
    public var day: String
    public var timeZoneID: String
    public var estimatedNanoseconds: UInt64?
    public var phase: Phase
    public var partial: Bool
    public var idleSeconds = 300
    public var generatedAt: Date
    public init(now: Date = Date(), timeZone: TimeZone = .current, estimatedNanoseconds: UInt64? = nil,
                phase: Phase = .notObserved, partial: Bool = false) {
        day = Self.dayKey(now, zone: timeZone); timeZoneID = timeZone.identifier
        self.estimatedNanoseconds = estimatedNanoseconds; self.phase = phase; self.partial = partial; generatedAt = now
    }
    public static func dayKey(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public var formatted: String { WidgetTimeSnapshot.duration(estimatedNanoseconds) }
    public var label: String {
        let state = phase == .active ? "활동 추정 중" : phase == .paused ? "자동 일시정지 · 추정" : "연결 필요 · 미관측"
        return state + (partial ? " · 일부 누락" : "")
    }
    public func stale(at now: Date) -> Bool { now.timeIntervalSince(generatedAt) > 90 || generatedAt > now.addingTimeInterval(5) || day != Self.dayKey(now, zone: .current) || timeZoneID != TimeZone.current.identifier }
}

public enum EstimatedActivitySignal: Sendable {
    case focus(Bool), activity(focused: Bool), heartbeat, gap
}

/// One monotonic receipt clock. Union of at most four editor connections.
/// Focus or activity grants a 5-minute eligibility window, but a heartbeat only
/// renews the 45-second connection lease. Neither is proof of human work.
public struct EstimatedActivityLedger: Sendable {
    private struct Window: Sendable { var sequence: Int64 = 0; var focused = false; var activity: UInt64?; var receipt: UInt64 = 0 }
    private var windows: [String: Window] = [:]
    private var lastTick: UInt64?
    private var lastWall: Date?
    public private(set) var snapshot: EstimatedActivitySnapshot
    private let idle: UInt64 = 300_000_000_000, lease: UInt64 = 45_000_000_000
    public init(now: Date = Date(), timeZone: TimeZone = .current) { snapshot = .init(now: now, timeZone: timeZone) }
    public mutating func restore(_ stored: EstimatedActivitySnapshot, now: Date, timeZone: TimeZone) {
        snapshot = .init(now: now, timeZone: timeZone, partial: true)
        if stored.day == snapshot.day && stored.timeZoneID == snapshot.timeZoneID,
           stored.version == 1, stored.idleSeconds == 300, stored.estimatedNanoseconds.map({ $0 <= 93_600_000_000_000 }) ?? true,
           stored.generatedAt <= now.addingTimeInterval(5) {
            snapshot.estimatedNanoseconds = stored.estimatedNanoseconds
            snapshot.phase = stored.estimatedNanoseconds == nil ? .notObserved : .paused
        }
        windows.removeAll(); lastTick = nil; lastWall = nil // Never restore active intervals.
    }
    public mutating func receive(id: String, sequence: Int64, signal: EstimatedActivitySignal,
                                 tick: UInt64, wall: Date, timeZone: TimeZone) {
        guard !id.isEmpty, id.utf8.count <= 128, sequence > 0 else { snapshot.partial = true; return }
        var window = windows[id] ?? Window()
        guard sequence > window.sequence else { return }
        if sequence != window.sequence + 1 { interrupt(tick: tick, wall: wall, timeZone: timeZone) }
        if case .gap = signal { interrupt(tick: tick, wall: wall, timeZone: timeZone) }
        else { advance(tick: tick, wall: wall, timeZone: timeZone) }
        guard windows[id] != nil || windows.count < 4 else { snapshot.partial = true; return }
        // A clock/day interruption invalidates focus, including the prior local copy.
        window = windows[id] ?? Window()
        window.sequence = sequence; window.receipt = tick
        switch signal {
        case .focus(let focus):
            window.focused = focus; window.activity = focus ? tick : nil
            if focus { for key in Array(windows.keys) where key != id { windows[key]?.focused = false } }
        case .activity(let focus):
            window.focused = focus; window.activity = focus ? tick : nil
            if focus { for key in Array(windows.keys) where key != id { windows[key]?.focused = false } }
        case .heartbeat: break
        case .gap: window.focused = false; window.activity = nil
        }
        windows[id] = window
        if window.focused && window.activity != nil && snapshot.estimatedNanoseconds == nil { snapshot.estimatedNanoseconds = 0 }
        updatePhase(at: tick)
    }
    public mutating func advance(tick: UInt64, wall: Date, timeZone: TimeZone) {
        let day = EstimatedActivitySnapshot.dayKey(wall, zone: timeZone)
        let changed = day != snapshot.day || timeZone.identifier != snapshot.timeZoneID
        if changed { snapshot = .init(now: wall, timeZone: timeZone, partial: true) }
        if let lastTick, let lastWall {
            guard !changed, tick >= lastTick,
                  abs(wall.timeIntervalSince(lastWall) - Double(tick - lastTick) / 1_000_000_000) < 2 else {
                interrupt(tick: tick, wall: wall, timeZone: timeZone); return
            }
            var until = lastTick
            for window in windows.values where window.focused {
                guard let activity = window.activity else { continue }
                let (idleEnd, io) = activity.addingReportingOverflow(idle), (leaseEnd, lo) = window.receipt.addingReportingOverflow(lease)
                guard !io && !lo else { snapshot.partial = true; continue }
                until = max(until, min(tick, idleEnd, leaseEnd))
            }
            if until > lastTick {
                let (sum, overflow) = (snapshot.estimatedNanoseconds ?? 0).addingReportingOverflow(until - lastTick)
                snapshot.estimatedNanoseconds = min(sum, 93_600_000_000_000); snapshot.partial = snapshot.partial || overflow
            }
            for id in Array(windows.keys) {
                if let w = windows[id], tick >= w.receipt, tick - w.receipt >= lease, w.focused {
                    windows[id]?.focused = false; windows[id]?.activity = nil; snapshot.partial = true
                }
            }
        }
        self.lastTick = tick; self.lastWall = wall; snapshot.generatedAt = wall
        updatePhase(at: tick)
    }
    public mutating func disconnect(id: String?, tick: UInt64, wall: Date, timeZone: TimeZone) {
        advance(tick: tick, wall: wall, timeZone: timeZone)
        if let id { windows.removeValue(forKey: id) } else { windows.removeAll() }
        snapshot.partial = true; updatePhase(at: tick)
    }
    public mutating func interrupt(tick: UInt64, wall: Date, timeZone: TimeZone) {
        if snapshot.day != EstimatedActivitySnapshot.dayKey(wall, zone: timeZone) || snapshot.timeZoneID != timeZone.identifier { snapshot = .init(now: wall, timeZone: timeZone) }
        windows.removeAll(); snapshot.partial = true; snapshot.generatedAt = wall
        lastTick = tick; lastWall = wall; updatePhase(at: tick)
    }
    private mutating func updatePhase(at tick: UInt64) {
        let active = windows.values.contains { w in
            guard w.focused, let a = w.activity, tick >= a, tick >= w.receipt else { return false }
            return tick - a < idle && tick - w.receipt < lease
        }
        snapshot.phase = active ? .active : snapshot.estimatedNanoseconds == nil ? .notObserved : .paused
    }
}
