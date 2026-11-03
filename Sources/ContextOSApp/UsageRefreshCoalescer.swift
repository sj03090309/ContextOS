import Foundation

/// One bounded-delay refresh for a burst of log writes. Later writes do not
/// postpone the deadline, so a continuously streaming session still updates.
@MainActor
final class UsageRefreshCoalescer {
    private var timer: Timer?
    var isPending: Bool { timer != nil }

    static func delay(visible: Bool, conservingEnergy: Bool) -> TimeInterval {
        visible ? (conservingEnergy ? 1 : 0.2) : (conservingEnergy ? 60 : 30)
    }

    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                action()
            }
        }
        timer.tolerance = min(5, delay * 0.1)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
