import SwiftUI

/// The shared work pose and independent optimization cue for both renderers.
@MainActor
final class MascotState: ObservableObject {
    static let workTransitionDuration: TimeInterval = 0.42
    private static let restTransitionDuration: TimeInterval = 0.56
    static let nodDuration: TimeInterval = 0.44
    static let completionDuration: TimeInterval = 2.6
    static let focusBreathPeriod: TimeInterval = 3.6
    static let restBreathPeriod: TimeInterval = 4.8
    nonisolated static let breathActiveFraction = 0.60
    static let breathPeakFraction = 0.39

    @Published private(set) var isWorking = false
    @Published private(set) var optimizationCompletedAt: Date?

    private(set) var workChangedAt: Date?
    private var poseAtChange: Double = 0
    private var poseDuration: TimeInterval { isWorking ? Self.workTransitionDuration : Self.restTransitionDuration }
    var workTransitionEnd: Date? { workChangedAt?.addingTimeInterval(poseDuration) }

    func setWorking(_ working: Bool, now: Date = Date()) {
        guard working != isWorking else { return }
        poseAtChange = workProgress(at: now)
        workChangedAt = now
        isWorking = working
    }

    func completeOptimization(at now: Date = Date()) {
        optimizationCompletedAt = now
    }

    /// 0 at rest and 1 standing, with continuity when work changes mid-transition.
    func workProgress(at now: Date) -> Double {
        let target: Double = isWorking ? 1 : 0
        guard let workChangedAt else { return target }
        let progress = now.timeIntervalSince(workChangedAt) / poseDuration
        return poseAtChange + (target - poseAtChange) * Self.ease(progress)
    }

    func isWorkTransitioning(at now: Date) -> Bool {
        guard let workChangedAt else { return false }
        return (0..<poseDuration).contains(now.timeIntervalSince(workChangedAt))
    }

    func isNodding(at now: Date) -> Bool {
        guard let optimizationCompletedAt else { return false }
        return (0..<Self.nodDuration).contains(now.timeIntervalSince(optimizationCompletedAt))
    }

    func nodProgress(at now: Date) -> Double {
        guard let optimizationCompletedAt, isNodding(at: now) else { return 0 }
        let progress = now.timeIntervalSince(optimizationCompletedAt) / Self.nodDuration
        return Self.pulse(progress, peak: 0.40)
    }

    func showsOptimizationCompletion(at now: Date) -> Bool {
        guard let optimizationCompletedAt else { return false }
        return (0..<Self.completionDuration).contains(now.timeIntervalSince(optimizationCompletedAt))
    }

    /// A short inhale, a longer exhale, then a quiet pause.
    static func breath(at time: Date, period: TimeInterval) -> Double {
        let phase = time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        return pulse(phase / breathActiveFraction, peak: breathPeakFraction)
    }

    private static func pulse(_ progress: Double, peak: Double) -> Double {
        progress < peak ? ease(progress / peak) : ease((1 - progress) / (1 - peak))
    }

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

/// Schedules frames for visible motion and jumps between pulses at rest.
struct MascotTimelineSchedule: TimelineSchedule {
    let gestureEnd: Date
    let breathPeriod: TimeInterval?

    private static let gestureInterval = 1.0 / 20
    private static let ambientInterval = 1.0 / 10
    private static let blinkPeriod: TimeInterval = 15
    private static let blinkStarts: [TimeInterval] = [1.2, 5.9, 11.8]
    private static let blinkDuration: TimeInterval = 0.24

    func entries(from startDate: Date, mode: Mode) -> some Sequence<Date> {
        sequence(first: startDate) { date in
            if date < gestureEnd {
                return mode == .lowFrequency ? gestureEnd
                    : min(gestureEnd, date.addingTimeInterval(Self.gestureInterval))
            }
            guard mode == .normal, let breathPeriod else { return nil }
            let breath = Self.nextPulseFrame(after: date, period: breathPeriod, starts: [0],
                                            duration: breathPeriod * MascotState.breathActiveFraction)
            let blink = Self.nextPulseFrame(after: date, period: Self.blinkPeriod,
                                            starts: Self.blinkStarts, duration: Self.blinkDuration)
            return min(breath, blink)
        }
    }

    static func blinkProgress(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blinkPeriod)
        for start in blinkStarts {
            let elapsed = phase - start
            if (0..<blinkDuration).contains(elapsed) {
                let closedAt = 0.08
                return elapsed < closedAt ? elapsed / closedAt : (blinkDuration - elapsed) / (blinkDuration - closedAt)
            }
        }
        return 0
    }

    private static func nextPulseFrame(after date: Date, period: TimeInterval, starts: [TimeInterval],
                                       duration: TimeInterval) -> Date {
        let cycle = floor(date.timeIntervalSinceReferenceDate / period) * period
        for start in starts {
            let begin = Date(timeIntervalSinceReferenceDate: cycle + start)
            if date < begin { return begin }
            let end = begin.addingTimeInterval(duration)
            if date < end { return min(end, date.addingTimeInterval(ambientInterval)) }
        }
        let nextCycle = Date(timeIntervalSinceReferenceDate: cycle + period + starts[0])
        // Fractional periods can round the next cycle start to the current date.
        return date < nextCycle ? nextCycle : date.addingTimeInterval(ambientInterval)
    }
}
