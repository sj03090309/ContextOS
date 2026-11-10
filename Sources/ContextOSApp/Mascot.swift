import SwiftUI

/// The shared work pose and independent optimization cue for both renderers.
@MainActor
final class MascotState: ObservableObject {
    static let workTransitionDuration: TimeInterval = 0.38
    static let nodDuration: TimeInterval = 0.36
    static let completionDuration: TimeInterval = 2.6
    static let focusBreathPeriod: TimeInterval = 3.6

    @Published private(set) var isWorking = false
    @Published private(set) var optimizationCompletedAt: Date?

    private(set) var workChangedAt: Date?
    private var poseAtChange: Double = 0

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
        let t = min(1, max(0, now.timeIntervalSince(workChangedAt) / Self.workTransitionDuration))
        let eased = t * t * (3 - 2 * t)
        return poseAtChange + (target - poseAtChange) * eased
    }

    func isWorkTransitioning(at now: Date) -> Bool {
        guard let workChangedAt else { return false }
        return (0..<Self.workTransitionDuration).contains(now.timeIntervalSince(workChangedAt))
    }

    func isNodding(at now: Date) -> Bool {
        guard let optimizationCompletedAt else { return false }
        return (0..<Self.nodDuration).contains(now.timeIntervalSince(optimizationCompletedAt))
    }

    func nodProgress(at now: Date) -> Double {
        guard let optimizationCompletedAt, isNodding(at: now) else { return 0 }
        let t = now.timeIntervalSince(optimizationCompletedAt) / Self.nodDuration
        let dip = sin(.pi * t)
        return dip * dip
    }

    func showsOptimizationCompletion(at now: Date) -> Bool {
        guard let optimizationCompletedAt else { return false }
        return (0..<Self.completionDuration).contains(now.timeIntervalSince(optimizationCompletedAt))
    }

    /// The same slow inhale and exhale in the dashboard and the menu bar.
    static func focusBreath(at time: Date) -> Double {
        let phase = time.timeIntervalSince1970.truncatingRemainder(dividingBy: focusBreathPeriod) / focusBreathPeriod
        return (1 - cos(2 * .pi * phase)) / 2
    }
}
