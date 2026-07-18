import SwiftUI
import ContextOSCore

/// How hard 뭉치 is chewing right now, shared by both renderers.
///
/// One object decides, both mascots read it, and the motion itself comes from
/// `MascotBeat`'s absolute clock — so the menu-bar glyph and the dashboard blob
/// can't disagree about *whether* to eat or about *which bite* is landing.
@MainActor
final class MascotState: ObservableObject {

    /// Whether an agent is working / ContextOS is optimizing right now.
    @Published private(set) var eating = false

    private var changedAt: Date?
    private var intensityAtChange: Double = 0

    /// Start or stop chewing. No-op sets are ignored so the ramp isn't restarted
    /// by every poll tick.
    func set(eating newValue: Bool, now: Date = Date()) {
        guard newValue != eating else { return }
        // Ramp from wherever the ease had actually reached, so stopping and
        // restarting inside a single ramp doesn't jump.
        intensityAtChange = intensity(at: now)
        changedAt = now
        eating = newValue
    }

    /// 0 (resting) … 1 (fully chewing) at `now`.
    func intensity(at now: Date) -> Double {
        guard let changedAt else { return eating ? 1 : 0 }
        return MascotBeat.ease(from: intensityAtChange, to: eating ? 1 : 0,
                               elapsed: now.timeIntervalSince(changedAt))
    }

    /// Whether anything is still moving — true through the whole ramp-down, so a
    /// renderer knows it can't go back to its idle frame rate yet.
    func isAnimating(at now: Date) -> Bool {
        eating || intensity(at: now) > 0.02
    }
}
