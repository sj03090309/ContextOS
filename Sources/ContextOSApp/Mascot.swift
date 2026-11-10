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
    static let breathActiveFraction = 0.60
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
