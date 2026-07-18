import Foundation

/// The one clock 뭉치 chews to.
///
/// 뭉치 is drawn twice — as an 18px template glyph in the menu bar, and as a
/// gooey metaball at the top of the dashboard — by two renderers with different
/// frame rates and lifetimes. They used to time the chew independently: from
/// different origins (the popover restarted its clock on every open), with
/// different periods (0.55s vs 0.85s), and at chomp frequencies that differed by
/// 0.67 rad/s. That last one is why they visibly drifted apart and back together
/// every few seconds: two oscillators that close beat against each other, here
/// with a period of 2π/0.67 ≈ 9.4 seconds.
///
/// So nothing here is relative to when a view appeared. Every value is a pure
/// function of the absolute wall clock, which both renderers agree on without
/// having to talk to each other — and which survives one of them being torn down
/// and recreated.
///
/// It lives in Core, away from the views, because it is arithmetic and because
/// the drift above is exactly the kind of bug that only tests catch.
public enum MascotBeat {

    /// Seconds for one full chew cycle: two bites, one per side.
    public static let cycle: Double = 0.55

    /// Bites in flight at once — one flying in from each side.
    public static let lanes = 2

    /// Time constant of the start/stop ease: it covers ~63% of the gap in this long.
    public static let ramp: Double = 0.22

    /// Where `lane`'s bite is on its flight into 뭉치: 0 (just launched) → 1
    /// (swallowed). Lanes are spread evenly through the cycle so bites arrive
    /// alternately rather than together.
    public static func foodPhase(_ time: Date, lane: Int) -> Double {
        let base = time.timeIntervalSince1970 / cycle + Double(lane) / Double(lanes)
        return base.truncatingRemainder(dividingBy: 1)
    }

    /// How sharply the mouth closes. Higher is snappier: the chomp spends more
    /// of the cycle at rest and slams shut in a brief spike.
    ///
    /// This is what "smoothness" actually means here, and it is free — a gentler
    /// curve moves less between two frames, so it reads as smoother at the *same*
    /// frame rate. Raising the frame rate to buy the same effect would cost ~0.6%
    /// of a core per extra swap per second.
    static let chompSharpness: Double = 2

    /// 0…1 chomp, peaking exactly as each bite lands.
    public static func chomp(_ time: Date) -> Double {
        // Two peaks per cycle — one per lane — hence 4π rather than 2π.
        let angle = 4 * Double.pi * time.timeIntervalSince1970 / cycle
        return pow((cos(angle) + 1) / 2, chompSharpness)
    }

    /// The resting breath, a slow sinusoid in -1…1.
    public static func breath(_ time: Date) -> Double {
        sin(time.timeIntervalSince1970 * 2.0)
    }

    /// A bite's opacity and scale over its flight: fades in, then shrinks away as
    /// 뭉치 swallows it.
    public static func foodFade(_ phase: Double) -> (opacity: Double, scale: Double) {
        let opacity = phase < 0.12 ? phase / 0.12
            : (phase > 0.82 ? max(0, (1 - phase) / 0.18) : 1)
        let scale = phase > 0.82 ? max(0.1, (1 - phase) / 0.18) : 1
        return (opacity, scale)
    }

    /// Exponential ease from `start` toward `target`, by elapsed **time**.
    ///
    /// Deliberately not the usual `value += (target - value) * k` applied once
    /// per frame: that makes the ramp's duration depend on the renderer's frame
    /// rate, so the menu bar's decimated 20/30fps and the popover's 60fps would
    /// ramp at visibly different speeds even with every other constant matched.
    public static func ease(from start: Double, to target: Double, elapsed: Double) -> Double {
        guard elapsed > 0 else { return start }
        let progress = 1 - exp(-elapsed / ramp)
        return start + (target - start) * progress
    }
}
